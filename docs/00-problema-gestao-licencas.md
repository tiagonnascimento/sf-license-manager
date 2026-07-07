# Gestão de Licenças Salesforce — Entendimento do Problema

> Resumo do deck _"COE - Gestão de Licenças"_ (Tiago Nascimento, Nov/2024).
> Objetivo deste documento: consolidar **o problema** que motiva a iniciativa, antes de
> desenhar uma **solução simplificada baseada em Excel** (alternativa à solução robusta
> proposta no deck, que usa custom objects + Unlocked Package).

---

## 1. As camadas de licença no Salesforce

O que você **compra** (comercial) é diferente do que é **aprovisionado** (técnico) na Org.

| Camada                            | O que é                                                                                                                               | Cardinalidade por usuário |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- | ------------------------- |
| **User License**                  | Licença-base do usuário; define funcionalidades básicas. Obrigatória.                                                                 | Exatamente **1**          |
| **Permission Set License (PSL)**  | Libera funcionalidades adicionais (conjunto de permissões).                                                                           | **0..N**                  |
| **Feature License**               | Funcionalidade pontual (toggle liga/desliga) vs. conjunto de permissões.                                                              | **0..N**                  |
| **Usage-based Entitlement (UBE)** | Direito de uso concedido por Produto/Add-on. Vale para **toda a Org**, não por usuário; soma conforme novos produtos são adicionados. | N/A (nível Org)           |

Além disso, para alguns produtos, **a aquisição de ao menos 1 licença libera funcionalidades/“settings” em toda a Org** (interruptores liga/desliga).

### Vocabulário-chave

- **Product License** = o que se compra (ex.: _Communications Cloud Advanced_, _Growth_, _Advanced Restricted Use_, _Customer Community Plus_…).
- **Setting Licenses** = o que efetivamente é aprovisionado na Org pelo produto (User License + PSLs + Feature Licenses + UBE).

---

## 2. O problema central: o uso de uma Product License é **ambíguo**

> Diferentes **Product Licenses** podem aprovisionar **exatamente o mesmo conjunto** de Setting Licenses na Org.

Como apenas a **User License** é obrigatória para aprovisionar um usuário, ele pode **não estar atribuído** ao PSL que diferenciaria os produtos — e ainda assim ser considerado “utilizando” a Product License. Logo, **olhar só a atribuição de licenças não determina, de forma inequívoca, qual produto o usuário está consumindo.**

### Casos que ilustram a ambiguidade

| #                                 | Cenário                                                                                                                                          | Por que a atribuição de licença não basta                                                                                                                         |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Restricted Use**                | _Communications Cloud Advanced_ vs. _Advanced (Restricted Use)_                                                                                  | Aprovisionam **as mesmas** Setting Licenses. A diferença é **apenas um acordo comercial** (limite **lógico**, não físico). Impossível distinguir pela atribuição. |
| **Advanced vs Growth**            | A única diferença é o PSL: `CommunicationsCloudPlusPsl` (Advanced) vs. `CommunicationsCloudPsl` (Growth). Demais Setting Licenses são idênticas. | Se a solução construída não depende desse PSL, o usuário pode não tê-lo atribuído e mesmo assim usar o produto.                                                   |
| **Customer Community (externo)**  | Dois tipos de Product License aprovisionam **a mesma** User License.                                                                             | Pelo relacionamento User License ↔ produto não dá para saber qual dos dois está em uso.                                                                          |
| **Add-ons com PSL compartilhado** | Mais de um Add-on pode aprovisionar **o mesmo PSL**.                                                                                             | A consulta simples à atribuição do PSL não isola qual Add-on está em uso.                                                                                         |

### Casos em que a determinação é direta (contraexemplos)

- **Partner Community**: existe só **um** tipo de Product License → o uso sai direto da atribuição da User License.
- **Add-ons que aprovisionam só UBE** (ex.: limites de uso): monitorados direto pelo consumo do entitlement.
- **Add-ons que só habilitam funcionalidade na Org** (ex.: _Comms Cloud BSS Suite_): sempre considerados “em uso”.

---

## 3. Mensagem-chave

> Para determinar **com precisão** que uma Product License está em uso, é preciso **mais** do que observar a atribuição de User License / PSL / Feature License. É necessária uma **camada analítica** que combine essas atribuições com **outras características do usuário** — **Perfil**, **Permission Sets / PS Groups**, etc.
>
> **Essa camada não existe nativamente nas Orgs Salesforce.**

A solução atual (time de Advisory da SF) monitora consumo de PSLs, mas não resolve a determinação inequívoca do produto. A evolução proposta adiciona essa camada analítica.

---

## 4. Solução robusta proposta no deck (referência)

Modelo de entidades (substitui os artefatos atuais `ContractxLicense__mdt`, `LicenseReport__c`, `BoardxVP__mdt`):

| Objeto                                   | Papel                                                                                                                                                                                                            | Mantido por      |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- |
| **ProductLicense\_\_c**                  | Catálogo de Product Licenses. Campos: `Type` (Base/Add-On), `Quantity` (rollup), `AssignedQuantity` (rollup), `AvailableQuantity` (fórmula), `Weight`, **`Query` (SOQL/critério que define quem usa a licença)** | App              |
| **ProductLicenseUserAssignment\_\_c**    | Detail: usuários atribuídos à licença. Campos: `UserId`, `IsActive`, `LastUserLoginDate`, `Username`, `UniqueConstraint`                                                                                         | App (via API)    |
| **ProductLicensePurchaseCondition\_\_c** | Detail: condições de compra. Campos: `Project`, `Domain`, `BoardOfDirectors`, `VicePresidency`, `Price`, `Quantity`, `PurchaseDate`                                                                              | Gestor de contas |

Características da solução robusta:

- Cada Product License tem uma **`Query` (SOQL)** como critério para determinar seus usuários (a “camada analítica”). COE apoia o negócio a montá-la; _query builder_ fica como evolução.
- UI Lightning padrão (sem LWC custom), rollups, relatórios gerenciais, distribuída como **Unlocked Package**.
- Pode rodar em sandbox/org não-produtiva; cargas inicialmente **manuais**, com evolução para **automação multi-org**.
- App: `github.com/tiagonnascimento/licenseManager` (v0.1.0-1).
- Dashboards: _Named Base Licenses_, _Add-ons & Login Licenses_, _Statistics_, _Users without Login (180 dias)_.

---

## 5. Insumos disponíveis para a versão simplificada (Excel)

Os dois CSVs já capturam a base do problema:

### `Usage Table` (estado por Setting License)

Colunas: **License, Activated, Provisioned, Used**. Snapshot do que está aprovisionado/usado por PSL/UBE na Org. Inclui também storage, sandboxes e limites de API/UBE.

### `SKU to License Matrix` (produto → setting licenses)

Matriz **Product Name × Setting License**, com a quantidade que cada SKU comprado aprovisiona de cada licença. É o mapa que liga o **comercial** (o que se comprou) ao **técnico** (o que foi aprovisionado) — exatamente o cruzamento que a ambiguidade exige.

> A peça que **falta** nos CSVs é a **camada por usuário** (Perfil + PS/PSL + último login), que é o que permite atribuir, inequivocamente, cada usuário a uma Product License — equivalente ao campo `Query` do modelo robusto, mas resolvido via extração + regras no Excel.

---

## 6. Próximo passo

Desenhar a **solução simplificada em Excel** que reproduza a “camada analítica” sem custom objects nem package:
extrações da org (usuários, perfis, permission sets, PSL assignments, last login) + as duas tabelas acima + uma planilha de **critérios por Product License** → pivôs de consumo (comprado vs. atribuído vs. usado).
