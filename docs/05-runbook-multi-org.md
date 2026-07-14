# Runbook — Consolidação Multi-Org (extensão não empacotada)

> Complementa a issue #4. A parte empacotada (dimensão `SourceOrg` carimbada em cada
> dataset, dashboard agrupando dinamicamente por `SourceOrg`) já vem pronta no pacote
> `LicenseManager` — com uma única org instalada, `SourceOrg` é simplesmente uma
> constante (`"Primary"`). Este documento cobre a **extensão manual** que cada
> administrador precisa fazer no próprio ambiente para consolidar **duas ou mais orgs**
> num único dashboard.

---

## 1. Objetivo & quando usar

Empresas com mais de uma org Salesforce produtiva (ex.: uma org B2B e uma org B2C, ou
orgs separadas por unidade de negócio/geografia) frequentemente querem um único
dashboard de utilização de licenças que enxergue **todas** as orgs, em vez de um
dashboard por org.

Use este runbook quando:

- O pacote `LicenseManager` já está instalado e funcionando (dados carregados, recipe
  rodando) em **duas ou mais orgs**, e
- Você quer consolidar os datasets `ProductLicenses`, `ProductLicensesWithUserAssignments`,
  `ProductLicensesWithPurchaseConditions` e/ou `ProductLicensePurchaseUtilization` de
  todas essas orgs em uma única instância de CRM Analytics (a "org hub").

## 2. Pré-requisitos

- O pacote `LicenseManager` instalado em **cada** org que participará da consolidação
  (org A, org B, ...), com os objetos `LM_ProductLicense__c`,
  `LM_ProductLicenseUserAssignment__c`, `LM_ProductLicensePurchaseCondition__c` etc.
  mantidos/atualizados em cada uma delas.
- O permission set `LM_LicenseManager` atribuído ao **Analytics Integration User** em
  cada org (necessário para o CRM Analytics conseguir ler os objetos `LM_` via Data Sync
  **e** para a recipe rodar — ela executa como esse usuário, não como você). Via CLI:

  ```bash
  # descubra o usuário de integração
  sf data query --query "SELECT Id, Name, Username FROM User WHERE Name LIKE '%Integration%' AND IsActive = true" --target-org <ORG>
  # atribua o permset a ele (não só ao seu próprio usuário)
  sf org assign permset --name LM_LicenseManager --target-org <ORG> --on-behalf-of <integration-username>
  ```

  > Se o permset não estiver no Integration User, a recipe roda mas os datasets vêm
  > vazios (o usuário não enxerga os objetos `LM_`).

- Definido qual org será a **org hub**: é nela que a recipe consolidada vai rodar e onde
  o dashboard final será visualizado. As demais orgs (org B, org C, ...) são apenas
  fonte de dados via conexão.
- Acesso de administrador na org hub para criar conexões do CRM Analytics (Data Manager
  → Connect to Data / Data Sync connections).

## 3. Passo a passo

### Passo 1 — Criar a conexão (Data Sync connection) para a org B

Na **org hub**, crie uma nova conexão do tipo Salesforce (Data Sync) apontando para a
org B:

- Data Manager → **Connect to Data** → **Connect a Salesforce Org**.
- Autentique com um usuário de integração da org B (o mesmo usuário com o permission
  set `LM_LicenseManager`, para garantir acesso aos objetos `LM_`).
- Dê um nome claro à conexão (ex.: `ORG_B_CONNECTION`) — esse nome é o
  `connectionName` que os nós `load` da recipe vão referenciar.

> Repita para cada org adicional (org C, org D, ...), uma conexão por org.

### Passo 2 — Adicionar os objetos `LM_` da org B como novos inputs na recipe

Abra a recipe `License_Manager_Datasets_Preparation` (Data Manager → Recipes) na org
hub em modo de edição:

- Para cada objeto `LM_` já usado como input na org atual (`LM_ProductLicense__c`,
  `LM_ProductLicenseUserAssignment__c`, `LM_ProductLicensePurchaseCondition__c`),
  adicione um **novo nó de input** apontando para o **mesmo objeto**, mas usando a
  conexão criada no Passo 1 (`ORG_B_CONNECTION`) em vez da conexão local (`SFDC_LOCAL`).
- Mantenha os mesmos campos selecionados no novo nó de input, para que o shape (schema)
  do ramo da org B seja compatível com o ramo da org A.

### Passo 3 — Carimbar cada ramo com seu próprio `SourceOrg`

Cada ramo de input deve carregar um nó de fórmula (`formula` — **nunca**
`computeExpression`, que é um enum inválido e derruba o deploy/save com o erro genérico
-505664367) que carimba a constante `SourceOrg`:

- Ramo da org A (já existe no pacote): `SourceOrg = "Primary"` (ou o nome real da org A,
  se preferir renomear).
- Ramo da org B (novo, criado neste runbook): `SourceOrg = "OrgB"` (ou o nome real da
  org B, ex.: `"B2C"`, `"LATAM"`, etc.).

Use o **mesmo schema de nó `formula` da recipe empacotada** (validado em API 67.0), só
troque o literal. O nó tem `expressionType: "SQL"` e um campo `TEXT` cuja
`formulaExpression` é o literal **entre aspas simples**:

```json
"parameters": {
  "expressionType": "SQL",
  "fields": [
    {
      "type": "TEXT",
      "name": "SourceOrg",
      "label": "SourceOrg",
      "formulaExpression": "'OrgB'",
      "precision": 255,
      "defaultValue": "OrgB"
    }
  ]
}
```

> ⚠️ **Não use** `saqlExpression`, `computedFields`, nem literal entre aspas duplas
> (`"OrgB"`). Esse schema antigo **salva/deploya sem erro** mas falha no **run-time** da
> recipe com `Specify fields for the <NODE> node` — o nó precisa de `formulaExpression`
> (não `saqlExpression`), container `fields` (não `computedFields`), `type: "TEXT"`
> (maiúsculo) e o literal em aspas simples. Confirmado em validação hands-on: com o
> schema correto a coluna `SourceOrg` popula (`"Primary"` na org de origem).

### Passo 4 — Fazer append (union) dos ramos antes de salvar cada dataset de saída

Antes do nó `save` de cada dataset final, insira um nó de **append** (union) que
combina o ramo carimbado da org A com o ramo carimbado da org B (e de quaisquer outras
orgs adicionadas). O resultado alimenta o mesmo nó `save` que já existe, mudando apenas
sua fonte (`sources`) de um único ramo para o nó de append.

Faça isso para cada dataset de saída que deve consolidar múltiplas orgs — no mínimo
`ProductLicensePurchaseUtilization` (o dataset usado pelo dashboard financeiro), mas o
mesmo padrão se aplica a `ProductLicenses` e `ProductLicensesWithUserAssignments` se
você quiser esses datasets também consolidados.

### Passo 5 — Re-rodar a recipe e (opcional) agendar

- Salve a recipe e clique em **Run Recipe** para popular os datasets com as linhas de
  ambas as orgs. (Alternativa headless, sem a Studio: `POST /wave/dataflowjobs` com
  `{"dataflowId":"<targetDataflowId>","command":"start"}` — atenção: use o
  `targetDataflowId` (`02K…`) obtido em `GET /wave/recipes/<id>?format=R3`, **não** o id
  da recipe (`05v…`); depois faça poll em `GET /wave/dataflowjobs/<jobId>` até `status`
  = `Success`.)
- Valide que cada dataset final tem pelo menos dois valores distintos de `SourceOrg`
  (ex.: `"Primary"` e `"OrgB"`). Via SAQL (`POST /wave/query`), agrupando por
  `SourceOrg`:

  ```
  q = load "<datasetId>/<versionId>";
  q = group q by 'SourceOrg';
  q = foreach q generate 'SourceOrg' as 'SourceOrg', count() as 'cnt';
  ```

  Deve retornar uma linha por org. Se voltar só `"Primary"`, o ramo da org B não foi
  carimbado/append corretamente (revise os Passos 3–4).

- Abra `License_Management_Dashboard` — como o dashboard já agrupa dinamicamente por
  `SourceOrg` (parte empacotada da issue #4), as duas orgs devem aparecer
  automaticamente, sem qualquer edição do dashboard.
- Opcionalmente, agende a recipe (Schedule Recipe) para manter os dados de ambas as
  orgs atualizados periodicamente.

## 4. Caveat — por que isso não é empacotado

Conexões Data Sync do CRM Analytics são **específicas do ambiente**: elas amarram uma
credencial concreta a uma org concreta (a conexão criada no Passo 1 só existe, e só
funciona, na org hub onde foi criada). Não há forma de empacotar uma "recipe com
conexão pronta" que funcione em qualquer instalação — cada cliente que quiser
consolidar múltiplas orgs precisa repetir os Passos 1–5 no próprio ambiente, com as
próprias conexões e credenciais.

Por isso:

- O pacote `LicenseManager` entrega apenas a **estrutura pronta para N ramos** (o
  carimbo de `SourceOrg` e o agrupamento dinâmico no dashboard), rodando same-org por
  padrão (uma constante `"Primary"`).
- Este runbook é o caminho documentado para estender essa estrutura manualmente.
- O arquivo de recipe-sample referenciado abaixo é **apenas ilustrativo**: ele aponta
  para uma conexão-placeholder que não existe em nenhuma org real, e serve só para
  mostrar visualmente o shape (2 inputs → carimbo por ramo → append → save). Ele
  **não** é instalado pelo pacote, **não** deve ser deployado, e precisa ser adaptado
  (nomes de conexão reais) antes de ter qualquer utilidade prática.

## 5. Onde está o exemplo

Veja `docs/samples/License_Manager_Datasets_Preparation_MultiOrg.wdpr` (e o
`docs/samples/README.md` que o acompanha) para o shape ilustrativo de 2 orgs aplicado
ao dataset `ProductLicensePurchaseUtilization`. É um arquivo de referência para copiar o
padrão — não um artefato para deploy.
