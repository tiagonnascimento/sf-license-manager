# docs/samples/ — arquivos de referência (NÃO empacotados)

Esta pasta contém artefatos **ilustrativos**, usados apenas como referência visual para
o [runbook multi-org](../05-runbook-multi-org.md) (issue #4). Nada aqui é deployado pelo
pacote `LicenseManager` nem é consumido por `sf project deploy` — a pasta vive fora de
`force-app/` justamente para ficar fora do pacote por construção.

## `License_Manager_Datasets_Preparation_MultiOrg.wdpr`

Versão ilustrativa, de 2 orgs, da recipe real
`force-app/main/default/wave/License_Manager_Datasets_Preparation.wdpr`, focada em um
único ramo (o de `LM_ProductLicense__c` alimentando o dataset de utilização financeira)
para demonstrar o padrão descrito no runbook:

1. Um branch de **input** por org (`load` → `formula` carimbando `SourceOrg`).
2. Um nó de **append** (union) combinando os branches carimbados.
3. Um único nó de **save** consumindo o resultado do append.

Pontos que tornam este arquivo claramente **não deployável / não real**:

- O topo do JSON tem um campo `_ILLUSTRATIVE_ONLY` explicando o propósito do arquivo —
  um campo que não existe no schema real de recipe e que, por si só, já sinaliza que
  isto não é um artefato de produção.
- O segundo branch (org B) usa `connectionName: "ORG_B_CONNECTION_PLACEHOLDER"`, uma
  conexão que **não existe** em nenhuma org real — é só um placeholder mostrando onde
  o admin deve colocar o nome da conexão Data Sync real criada no Passo 1 do runbook.
- O dataset de saída usa o nome `ProductLicensePurchaseUtilization_MultiOrg_SAMPLE`,
  distinto do dataset real do pacote (`ProductLicensePurchaseUtilization`), para não
  colidir nem ser confundido com ele.

**Não tente deployar este arquivo.** Ele serve para copiar o padrão de
input→carimbo→append→save e adaptá-lo, no editor de recipes da própria org hub, com os
nomes de conexão e datasets reais do seu ambiente (ver `docs/05-runbook-multi-org.md`).
