/**
 * ========================================================================================
 * GOOGLE APPS SCRIPT (GAS) — INTEGRAÇÃO DE GESTÃO DE COMPRAS E OCS COM O DASHBOARD
 * ========================================================================================
 * Este script deve ser inserido no Editor de Scripts da Planilha Google (Extensões > Apps Script)
 * Ele sincroniza automaticamente as linhas da planilha de Ordens de Compra e Obras
 * diretamente com o banco de dados Supabase e dispara webhooks de ocorrência.
 *
 * CHANGELOG v2.0 — Blindagem Completa:
 *   1. Bloqueio de loop infinito (ignora edições na coluna G e usa mutex)
 *   2. Validação de linha completa (OC + Produto obrigatórios)
 *   3. Suporte a paste de múltiplas linhas (getNumRows)
 *   4. Batch otimizado (pula linhas sem modificação via flag na coluna I)
 *   5. formatISODate retorna null para datas inválidas/vazias
 *   6. Feedback visual: verde (sucesso) / vermelho (erro) na célula da OC
 *
 * LAYOUT DA PLANILHA ESPERADO:
 *   A = Número da OC
 *   B = Departamento
 *   C = Status
 *   D = Previsão de Entrega
 *   E = Descrição / Pedido
 *   F = Chave NF-e
 *   G = ID do Supabase (taskId) — GERENCIADA PELO SCRIPT, NÃO EDITAR MANUALMENTE
 *   H = Produto
 *   I = Flag de modificação — GERENCIADA PELO SCRIPT (TRUE = pendente de sync)
 * ========================================================================================
 */

// =====================================================================================
// CONFIGURAÇÕES GLOBAIS
// =====================================================================================
var CONFIG = {
  SUPABASE_URL: "https://ouceggqyzynvhltozlut.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im91Y2VnZ3F5enludmhsdG96bHV0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc5MzAxMzUsImV4cCI6MjEwMzUwNjEzNX0.p5FgH0VTIxPGhUQ-DYXJmElAKs1E4cy3_yxEXSwpw1A",
  SHEET_NAME_OCS: "OrdensDeCompra",
  SHEET_NAME_OBRAS: "ObrasHistorico",
  DEFAULT_USER_ID: "sistema_gas_b2b",

  // Colunas (1-indexed)
  COL_OC:          1,  // A — Número da OC
  COL_DEPARTMENT:  2,  // B — Departamento
  COL_STATUS:      3,  // C — Status
  COL_DUE_DATE:    4,  // D — Previsão de Entrega
  COL_DESCRIPTION: 5,  // E — Descrição / Pedido
  COL_NFE:         6,  // F — Chave NF-e
  COL_TASK_ID:     7,  // G — ID do Supabase (taskId)
  COL_PRODUCT:     8,  // H — Produto
  COL_DIRTY_FLAG:  9,  // I — Flag de modificação
  TOTAL_COLUMNS:   9,

  // Cores de feedback visual
  COLOR_SUCCESS: "#d4edda",  // Verde claro
  COLOR_ERROR:   "#f8d7da"   // Vermelho claro
};

// Colunas gerenciadas pelo script que NÃO devem re-disparar o onEdit
var SCRIPT_MANAGED_COLUMNS = [CONFIG.COL_TASK_ID, CONFIG.COL_DIRTY_FLAG];


// =====================================================================================
// TRIGGER: onEdit(e)
// =====================================================================================
/**
 * Trigger que dispara automaticamente ao editar a planilha.
 *
 * Blindagens implementadas:
 *   - Ignora edições nas colunas G (taskId) e I (dirty flag) para evitar loop infinito
 *   - Valida que a linha possui OC e Produto/Descrição antes de enviar
 *   - Suporta paste de múltiplas linhas via getNumRows()
 *   - Marca coluna I como TRUE para linhas editadas (usado pelo batch)
 */
function onEdit(e) {
  if (!e || !e.range) return;

  var sheet = e.source.getActiveSheet();
  var sheetName = sheet.getName();

  // Só processa a aba de Ordens de Compra
  if (sheetName !== CONFIG.SHEET_NAME_OCS) return;

  var range = e.range;
  var editedCol = range.getColumn();

  // -----------------------------------------------------------------------
  // BLOQUEIO DE LOOP INFINITO
  // Se a edição foi em uma coluna gerenciada pelo script (G ou I), sai.
  // Isso impede que a gravação do taskId na coluna G re-dispare o onEdit.
  // -----------------------------------------------------------------------
  for (var c = 0; c < SCRIPT_MANAGED_COLUMNS.length; c++) {
    // Verifica se alguma coluna do range editado cai numa coluna gerenciada
    var lastEditedCol = editedCol + range.getNumColumns() - 1;
    if (editedCol <= SCRIPT_MANAGED_COLUMNS[c] && lastEditedCol >= SCRIPT_MANAGED_COLUMNS[c]) {
      // Se o range SÓ contém colunas gerenciadas, sai completamente
      if (range.getNumColumns() <= SCRIPT_MANAGED_COLUMNS.length) {
        return;
      }
    }
  }

  // Proteção extra: se já estamos em sincronização, sai
  var scriptProps = PropertiesService.getScriptProperties();
  if (scriptProps.getProperty("SYNCING") === "true") return;

  // -----------------------------------------------------------------------
  // SUPORTE A PASTE DE MÚLTIPLAS LINHAS
  // -----------------------------------------------------------------------
  var startRow = range.getRow();
  var numRows = range.getNumRows();

  for (var i = 0; i < numRows; i++) {
    var currentRow = startRow + i;

    // Ignora o cabeçalho (linha 1)
    if (currentRow <= 1) continue;

    // -----------------------------------------------------------------------
    // VALIDAÇÃO DE LINHA COMPLETA
    // Só envia se OC (coluna A) e Produto/Descrição (coluna H ou E) existirem
    // -----------------------------------------------------------------------
    var rowData = sheet.getRange(currentRow, 1, 1, CONFIG.TOTAL_COLUMNS).getValues()[0];
    var ocNumber = rowData[CONFIG.COL_OC - 1];
    var produto = rowData[CONFIG.COL_PRODUCT - 1] || rowData[CONFIG.COL_DESCRIPTION - 1];

    if (!ocNumber || !produto) {
      // Linha incompleta — o usuário ainda está digitando, não envia
      continue;
    }

    // Marca a flag de modificação na coluna I (para o batch saber que houve edição)
    sheet.getRange(currentRow, CONFIG.COL_DIRTY_FLAG).setValue(true);

    // Sincroniza a linha com o Supabase
    syncOrderRowToSupabase(sheet, currentRow);
  }
}


// =====================================================================================
// CORE: Sincronização de uma linha individual
// =====================================================================================
/**
 * Lê uma linha específica da planilha, monta o payload e envia/atualiza no Supabase.
 * Inclui feedback visual (cor da célula) e proteção de mutex.
 *
 * @param {Sheet} sheet - A aba da planilha
 * @param {number} row - Número da linha (1-indexed)
 */
function syncOrderRowToSupabase(sheet, row) {
  var rowData = sheet.getRange(row, 1, 1, CONFIG.TOTAL_COLUMNS).getValues()[0];

  var ocNumber    = rowData[CONFIG.COL_OC - 1];
  var department  = rowData[CONFIG.COL_DEPARTMENT - 1] || "Compras";
  var status      = mapStatusToDashboard(rowData[CONFIG.COL_STATUS - 1]);
  var dueDate     = formatISODate(rowData[CONFIG.COL_DUE_DATE - 1]);
  var description = rowData[CONFIG.COL_DESCRIPTION - 1] || "";
  var nfeKey      = rowData[CONFIG.COL_NFE - 1] || "";
  var taskId      = rowData[CONFIG.COL_TASK_ID - 1] || "";
  var produto     = rowData[CONFIG.COL_PRODUCT - 1] || description;

  // Validação final de segurança (caso chamada diretamente fora do onEdit)
  if (!ocNumber) return;

  // Célula da OC para feedback visual
  var ocCell = sheet.getRange(row, CONFIG.COL_OC);

  // Monta o payload
  var payload = {
    title: "Tarefa: Receber OC-" + ocNumber + " | Produto: " + produto,
    type: "delivery",
    group_name: department,
    status: status,
    due_date: dueDate,
    description: "Pedido chegando.\nProduto: " + produto +
                 "\nOC: " + ocNumber +
                 "\nDetalhes: " + description +
                 (nfeKey ? "\nChave NF-e: " + nfeKey : ""),
    user_id: CONFIG.DEFAULT_USER_ID
  };

  var options = {
    method: taskId ? "patch" : "post",
    headers: {
      "apikey": CONFIG.SUPABASE_ANON_KEY,
      "Authorization": "Bearer " + CONFIG.SUPABASE_ANON_KEY,
      "Content-Type": "application/json",
      "Prefer": "return=representation"
    },
    payload: JSON.stringify(payload),
    muteHttpExceptions: true
  };

  var endpoint = CONFIG.SUPABASE_URL + "/rest/v1/tasks" +
                 (taskId ? "?id=eq." + taskId : "");

  try {
    var response = UrlFetchApp.fetch(endpoint, options);
    var resCode = response.getResponseCode();

    if (resCode === 200 || resCode === 201) {
      var resJson = JSON.parse(response.getContentText());

      // Se é um POST (novo registro) e o Supabase retornou o ID, grava na coluna G
      if (resJson && resJson.length > 0 && !taskId) {
        // Ativa mutex antes de gravar na coluna G para evitar re-trigger
        var scriptProps = PropertiesService.getScriptProperties();
        scriptProps.setProperty("SYNCING", "true");

        try {
          sheet.getRange(row, CONFIG.COL_TASK_ID).setValue(resJson[0].id);
        } finally {
          scriptProps.deleteProperty("SYNCING");
        }
      }

      // Limpa a flag de modificação (coluna I) após sync bem-sucedido
      var scriptProps2 = PropertiesService.getScriptProperties();
      scriptProps2.setProperty("SYNCING", "true");
      try {
        sheet.getRange(row, CONFIG.COL_DIRTY_FLAG).setValue("");
      } finally {
        scriptProps2.deleteProperty("SYNCING");
      }

      // FEEDBACK VISUAL: Verde claro na célula da OC
      ocCell.setBackground(CONFIG.COLOR_SUCCESS);
      ocCell.setNote("");  // Limpa nota de erro anterior, se existia

      Logger.log("✅ OC " + ocNumber + " (linha " + row + ") sincronizada com sucesso.");

    } else {
      // FEEDBACK VISUAL: Vermelho claro + nota com o erro
      var errorMsg = "Erro " + resCode + ": " + response.getContentText().substring(0, 200);
      ocCell.setBackground(CONFIG.COLOR_ERROR);
      ocCell.setNote("⚠ Falha no Supabase\n" + errorMsg);

      Logger.log("❌ Erro na sincronização da OC " + ocNumber + " (linha " + row + "): " + errorMsg);
    }

  } catch (err) {
    // FEEDBACK VISUAL: Vermelho claro + nota com a exceção
    ocCell.setBackground(CONFIG.COLOR_ERROR);
    ocCell.setNote("⚠ Exceção na conexão\n" + err.toString().substring(0, 200));

    Logger.log("❌ Exceção ao sincronizar OC " + ocNumber + " (linha " + row + "): " + err.toString());
  }
}


// =====================================================================================
// BATCH: Sincronização em lote (Trigger de Tempo)
// =====================================================================================
/**
 * Função agendada (Trigger de Tempo) para varredura e conciliação em lote.
 *
 * OTIMIZAÇÃO: Pula linhas que já possuem taskId na coluna G E NÃO possuem
 * a flag de modificação (coluna I) marcada. Isso evita iterar sobre todo o
 * histórico antigo e estourar o limite de 6 minutos do GAS.
 *
 * Apenas processa:
 *   - Linhas SEM taskId (nunca foram enviadas ao Supabase)
 *   - Linhas COM taskId MAS com flag de modificação = TRUE (foram editadas após envio)
 */
function syncAllOrdersBatch() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(CONFIG.SHEET_NAME_OCS);
  if (!sheet) return;

  var lastRow = sheet.getLastRow();
  if (lastRow < 2) return;

  // Lê todas as linhas de uma vez para performance (evita getRange repetido)
  var allData = sheet.getRange(2, 1, lastRow - 1, CONFIG.TOTAL_COLUMNS).getValues();

  var processedCount = 0;
  var skippedCount = 0;

  for (var i = 0; i < allData.length; i++) {
    var rowIndex = i + 2; // Linha real na planilha (1-indexed, pulando cabeçalho)
    var rowData = allData[i];

    var ocNumber = rowData[CONFIG.COL_OC - 1];
    var produto  = rowData[CONFIG.COL_PRODUCT - 1] || rowData[CONFIG.COL_DESCRIPTION - 1];
    var taskId   = rowData[CONFIG.COL_TASK_ID - 1];
    var dirtyFlag = rowData[CONFIG.COL_DIRTY_FLAG - 1];

    // Pula linhas sem dados essenciais
    if (!ocNumber || !produto) {
      skippedCount++;
      continue;
    }

    // OTIMIZAÇÃO: Pula linhas que já têm taskId e NÃO foram modificadas
    if (taskId && !dirtyFlag) {
      skippedCount++;
      continue;
    }

    // Sincroniza a linha
    syncOrderRowToSupabase(sheet, rowIndex);
    processedCount++;

    // Rate limiting amigável para não estourar cotas
    Utilities.sleep(200);
  }

  Logger.log("📊 Batch concluído: " + processedCount + " linhas processadas, " +
             skippedCount + " linhas puladas.");
}


// =====================================================================================
// HELPERS
// =====================================================================================

/**
 * Mapeia o status da planilha para o formato do Dashboard.
 * @param {string} sheetStatus - Texto de status da planilha
 * @returns {string} - "done", "in_progress" ou "pending"
 */
function mapStatusToDashboard(sheetStatus) {
  var s = String(sheetStatus).toLowerCase();
  if (s.includes("entreg") || s.includes("conclu")) return "done";
  if (s.includes("rota") || s.includes("andamento") || s.includes("transit")) return "in_progress";
  return "pending";
}

/**
 * Converte um valor de data para string ISO 8601.
 *
 * CORREÇÃO v2.0: Se a célula de data estiver vazia ou inválida,
 * retorna null em vez de injetar a data atual. Isso permite que o
 * Supabase lide com o campo nulo corretamente, sem criar falsas
 * urgências de entregas para "hoje".
 *
 * @param {*} dateVal - Valor da célula de data
 * @returns {string|null} - ISO string ou null
 */
function formatISODate(dateVal) {
  // Vazio, undefined, null, string vazia
  if (!dateVal && dateVal !== 0) return null;

  // Se já é um objeto Date válido
  if (dateVal instanceof Date) {
    if (isNaN(dateVal.getTime())) return null;
    return dateVal.toISOString();
  }

  // Tenta converter string/número para Date
  try {
    var d = new Date(dateVal);
    if (isNaN(d.getTime())) return null;
    return d.toISOString();
  } catch (e) {
    return null;
  }
}


// =====================================================================================
// UTILITÁRIO: Menu customizado (opcional)
// =====================================================================================
/**
 * Adiciona um menu customizado na planilha para executar o batch manualmente.
 */
function onOpen() {
  SpreadsheetApp.getUi()
    .createMenu("⚡ Supabase Sync")
    .addItem("🔄 Sincronizar Pendentes (Batch)", "syncAllOrdersBatch")
    .addItem("🧹 Limpar Cores de Feedback", "clearFeedbackColors")
    .addToUi();
}

/**
 * Limpa as cores de feedback visual de todas as linhas.
 */
function clearFeedbackColors() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(CONFIG.SHEET_NAME_OCS);
  if (!sheet) return;

  var lastRow = sheet.getLastRow();
  if (lastRow < 2) return;

  sheet.getRange(2, CONFIG.COL_OC, lastRow - 1, 1).setBackground(null);
  sheet.getRange(2, CONFIG.COL_OC, lastRow - 1, 1).clearNote();

  Logger.log("🧹 Cores e notas de feedback limpas.");
}
