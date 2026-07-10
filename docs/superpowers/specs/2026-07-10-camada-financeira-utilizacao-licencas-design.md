# Camada Financeira de Utilização de Licenças — Design

> Spec derivada do issue #1 ("Automate UserAssignment generation & link Personas to Purchase Conditions").
> Data: 2026-07-10. Autor: Tiago Nascimento (com Claude Code).
> Objetivo: evoluir o `LicenseManager` para extrair dados financeiros de utilização de licença
> de forma apropriada — custo de desperdício por compra, chargeback/rateio e forecast de renovação —
> resolvendo o gap estrutural em que a utilização só existe no grão do Product License.

---

## 1. Problema

Hoje `LM_ProductLicensePersona__c`, `LM_ProductLicensePurchaseCondition__c` e
`LM_ProductLicenseUserAssignment__c` penduram em `LM_ProductLicense__c` por master-detail,
mas **nenhum se relaciona com o outro**. O recipe/dataflow do CRM Analytics
(`force-app/main/default/wave/License_Manager_Datasets_Preparation`) junta
`UserAssignment → ProductLicense` e `PurchaseCondition → ProductLicense` como dois LOOKUP
separados que só se encontram no grão do **Product License**.

Consequência: quando um Product License tem várias compras (Boards / VPs / projetos diferentes),
o dashboard mostra _total comprado vs total em uso por Product License_, mas **não consegue
segregar quanto de uma compra específica está de fato em uso** — toda a utilização cai no
mesmo balde. Sem essa segregação, nenhuma métrica financeira por compra é possível.

Além disso, `LM_ProductLicenseUserAssignment__c` é um dataset **derivado** que deveria ser gerado
por automação (rodar a `Query__c` de cada Persona e materializar os usuários) — automação que
**ainda não existe** (item de roadmap). O momento de automatizar é o momento de atribuir cada
usuário gerado a uma compra.

## 2. Metas (o que a spec entrega)

Em ordem de dependência:

1. **Normalização de preço unitário** (pré-requisito de tudo). `Price` da compra é o _total_;
   derivar `UnitPrice = Price / Quantity`.
2. **Custo de desperdício por compra** — quanto (R$) está parado em licenças compradas e não
   utilizadas, por compra / Board / VP / projeto.
3. **Chargeback / rateio** — custo do que está em uso, atribuído de forma **real** (não estimada)
   ao Board / VP / projeto dono de cada compra.
4. **Forecast de renovação** — custo **contratado** das compras que vencem numa janela, cruzado
   com o desperdício atual para apoiar decisões de renovar / reduzir / cancelar.

## 3. Arquitetura em três camadas

Cada camada tem uma responsabilidade única e um limite claro:

| Camada             | Responsabilidade                                                                           | Tecnologia                      | Mantida por   |
| ------------------ | ------------------------------------------------------------------------------------------ | ------------------------------- | ------------- |
| **Definição**      | Declarar qual população pertence a quais compras, e em que proporção                       | Declarativo (junction object)   | Negócio / COE |
| **Materialização** | Rodar as `Query__c`, resolver conflitos e gerar `UserAssignment` carimbado com a compra    | Apex Batch/Schedulable          | App           |
| **Financeira**     | Calcular custo unitário, desperdício, rateio e forecast; agregar por Board/VP/projeto/data | CRM Analytics (recipe/dataflow) | App           |

**Princípio central — alocação determinística.** Cada `UserAssignment` é um registro **inteiro**
carimbado com **exatamente uma** `PurchaseCondition`. Um usuário nunca é fracionado entre compras.
Isso mantém o Apex simples e determinístico e permite que o CRM Analytics agregue **registros
reais**, sem nenhuma matemática de ponderação no recipe. O rateio por Board/VP passa a ser real,
não estimado.

## 4. Modelo de dados (mudanças)

Todas declarativas, prefixo `LM_`.

### 4.1 Novo objeto de junção `LM_PersonaPurchaseAllocation__c`

Junction entre Persona e Purchase Condition.

- `Persona__c` — **master-detail** para `LM_ProductLicensePersona__c` (a allocation não existe sem
  a Persona; herda segurança e ciclo de vida).
- `PurchaseCondition__c` — lookup para `LM_ProductLicensePurchaseCondition__c`.
- `Weight__c` — cota de partição (Percent ou Number). Consumida pelo Apex **apenas** quando a
  mesma Persona liga a mais de uma compra do mesmo Product License. Quando a Persona liga a uma só
  compra, é 100% implícito.

Validação da soma dos pesos por Persona é feita no **Apex** (envolve agregação), não como regra
declarativa.

### 4.2 `LM_ProductLicenseUserAssignment__c` — novos lookups

- `PurchaseCondition__c` — lookup. O **carimbo determinístico**: cada assignment aponta para uma
  compra. Habilita rollup de `AssignedQuantity` por compra e todas as métricas financeiras.
- `Persona__c` — lookup para a Persona que gerou o registro (auditoria e rastreabilidade).

### 4.3 `UniqueConstraint__c` — permanece como está

Chave = `Username|Type`. **Não** ganha dimensão de compra: como a alocação é determinística, um
usuário Base cai em uma única compra mesmo quando a Persona liga a várias — logo `Username|Type`
já garante "um Base por usuário". A compra é atributo do registro, não dimensão de unicidade.
Continua servindo de safety-net _dentro_ de uma execução.

### 4.4 O que NÃO muda

- `PurchaseCondition.Price` continua o **total** da compra; `UnitPrice` é derivado no Analytics,
  não persistido.
- `LM_ProductLicense__c.Weight__c` continua onde está (desempate entre Personas Base concorrentes).

## 5. Motor de materialização (Apex)

`Database.Batchable` + `Schedulable` wrapper para agendamento nativo. Padrão
**truncate-and-reload**.

### 5.1 Fluxo

0. **Truncate** — deleta **todos** os `UserAssignment` no início (full refresh). Elimina lógica de
   órfãos e idempotência entre execuções: cada run é um retrato limpo do estado atual da org.
1. **Passada 1 — Base (desempate por Weight):** lê Personas de Product Licenses **Base**
   ordenadas por `ProductLicense.Weight__c` desc; executa cada `Query__c` (`Database.query`
   dinâmico). Usuário que casa com várias Personas Base fica só na de **maior Weight**; as demais
   o descartam. Resultado: cada usuário → no máximo uma Persona Base.
2. **Passada 2 — Add-ons:** executadas independentemente (um usuário pode ter vários add-ons
   distintos), sem o desempate exclusivo.
3. **Partição por compra (dentro de cada Persona):**
   - Carrega as allocations da Persona → lista de `(compra, peso)`.
   - **Caso trivial (1 allocation):** todos os usuários recebem aquela compra.
   - **Caso ponderado (N allocations):** ordena usuários por `CreatedDate`, compras por
     `PurchaseDate`; distribui na proporção dos pesos **sobre o total retornado** (nunca trunca).
     Arredonda cada fatia; o resto por diferença cai na compra de `PurchaseDate` mais recente
     (soma sempre fecha com o total).
4. **Insert** dos `UserAssignment`, cada um com `PurchaseCondition__c` e `Persona__c` preenchidos.

### 5.2 Overflow

O Apex **nunca trunca** para caber na `Quantity` comprada. Se a query retorna mais usuários do que
o total comprado, todos são materializados e o excedente aparece como **sobre-utilização** na
camada analítica (`WasteQty` negativo). O modelo nunca esconde o excedente.

### 5.3 Escala

`Database.query` respeita limites de linha; para populações grandes (ex.: milhões de Customer
Community na Vivo) o batch processa por Persona (scope) e faz DML em lotes. Chunking / `LIMIT`
na query dinâmica a validar na implementação.

### 5.4 Janela de indisponibilidade

Truncate-and-reload deixa a tabela vazia/parcial durante o batch. Aceitável porque o recipe do
CRM Analytics roda **depois** do batch (batch → recipe → dashboard). Zero-downtime (upsert +
desativa) fica como evolução futura se necessário.

## 6. Camada financeira (CRM Analytics)

Com cada `UserAssignment` carimbado com uma compra, o recipe agrega **registros reais**, sem
ponderação. Todas as métricas derivadas no recipe/dashboard.

### 6.1 Base — normalização de preço

- `UnitPrice = PurchaseCondition.Price / PurchaseCondition.Quantity` (custo por licença comprada,
  por compra).

### 6.2 Meta 2 — desperdício por compra

- `AssignedByPurchase` = contagem de `UserAssignment` ativos agrupados por `PurchaseCondition__c`.
- `WasteQty = Quantity − AssignedByPurchase` (negativo = sobre-utilização, visível de propósito).
- `WasteCost = WasteQty × UnitPrice`.
- Agregável por Board / VP / Projeto / Domain (campos já existentes na PurchaseCondition).

### 6.3 Meta 3 — chargeback / rateio

- `UsedCost = AssignedByPurchase × UnitPrice` — custo do que está em uso, atribuível ao
  Board/VP/Projeto dono da compra. Rateio **real** (carimbo determinístico), não estimado.

### 6.4 Meta 4 — forecast de renovação

- Cruza `ContractStartDate` / `ContractEndDate` com `AssignedByPurchase`.
- `ProjectedCost` = **custo contratado** (`Quantity × UnitPrice`) das compras ativas que vencem na
  janela. **Não** extrapola utilização — é o custo do que está contratado, apresentado ao lado do
  desperdício atual para o gestor decidir.
- `RenewalRisk` (indicativo): compras vencendo em N dias com `WasteQty` alto = candidatas a
  reduzir/cancelar; `WasteQty` negativo = candidatas a aumentar.

### 6.5 Impacto no recipe/dataflow existente

- Hoje: dois LOOKUP separados que só se encontram no grão do Product License.
- Agora: `UserAssignment` tem `PurchaseCondition__c` direto → novo LOOKUP
  `UserAssignment → PurchaseCondition`; métricas passam a viver no grão da **compra**.
- Manter `.wdf` (dataflow) e `.wdpr` (recipe) em paralelo — convenção da app.

## 7. Testes e validação

### 7.1 Apex (≥75% cobertura — exigência do unlocked package)

- Desempate por Weight: usuário em duas Personas Base → cai na de maior peso.
- Partição trivial: 1 compra → 100% dos usuários.
- Partição ponderada com resto: 91 usuários em junction 60/40 → 55/36, resto na compra de
  `PurchaseDate` mais recente.
- Truncate-and-reload: segunda execução reflete query alterada (sem órfãos).
- Add-ons: passada 2 gera múltiplos assignments distintos para o mesmo usuário.

### 7.2 CRM Analytics

- Validar `WasteCost` e `UsedCost` por Board contra cálculo manual sobre os dados de amostra.
- Caso de overflow: assignments > Quantity → `WasteQty` negativo aparece no dashboard.

### 7.3 Dados de amostra (SFDMU)

- `scripts/data/sfdmu/export.json` ganha o novo objeto `LM_PersonaPurchaseAllocation__c` e os
  lookups em `UserAssignment`.
- Incluir **add-ons** na amostra (nunca exercitados até hoje) para validar a passada 2.

## 8. Decisões registradas

1. Metas: desperdício por compra + chargeback/rateio + forecast de renovação, com preço unitário
   normalizado como base.
2. Junction `Persona↔PurchaseCondition` com `Weight__c` explícito; `Persona__c` master-detail.
3. Alocação usuário→compra **determinística** (lookup `PurchaseCondition__c` no UserAssignment);
   peso só consumido quando a **mesma** Persona liga a várias compras.
4. Overflow nunca truncado no Apex — vira sobre-utilização no Analytics.
5. Match: usuários por `CreatedDate`, compras por `PurchaseDate`; resto do arredondamento na compra
   mais recente.
6. Motor: Apex Batch/Schedulable, **truncate-and-reload** (introduz o primeiro Apex da app).
7. Cálculo financeiro na camada CRM Analytics.
8. Forecast = custo contratado, sem projetar utilização.
9. `UniqueConstraint__c` permanece `Username|Type` — sem dimensão de compra.

## 9. Fora de escopo

- Query builder / UI para montar `Query__c` (evolução futura já prevista no deck original).
- Zero-downtime na materialização (padrão upsert+desativa).
- Extrapolação de utilização no forecast.
- Reconciliação automática com a planilha de contratos (feita à mão no vivob2b).
