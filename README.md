# Tasks

## Atendimento automático com IA

### Banco de dados

Execute `supabase_schema.sql` no SQL Editor do Supabase. O arquivo pode ser executado novamente: recria as políticas e triggers e adiciona as colunas/tabelas da fila sem apagar as conversas existentes. A fila `ai_reply_jobs` não é acessível aos usuários autenticados; o worker a acessa com a chave `service_role`.

### Worker

1. Copie `.env.example` para `.env` e configure `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `AI_PROVIDER`, `AI_API_KEY` e `AI_MODEL`. A chave `service_role` e a chave do provedor são segredos de servidor: nunca as coloque no HTML ou no Git.
2. Instale as dependências com `pip install -r requirements.txt`.
3. Inicie o processo persistente com `python chat_ai_worker.py`. Em produção, mantenha-o sob um supervisor de processos/contêiner e monitore seus logs. `AI_WORKER_POLL_SECONDS` e `AI_WORKER_BATCH_SIZE` controlam o polling.

Provedores suportados: `openai`, `anthropic`, `google`, `deepseek`, `moonshot`, `openrouter` e `mistral`. Para provedores compatíveis com a API de chat da OpenAI, configure também `AI_API_BASE_URL`. Defina `AI_MODEL` com o identificador aceito pelo provedor. O worker descarta mensagens com mais de `AI_MAX_MESSAGE_AGE_MINUTES` (padrão: 60), evitando respostas atrasadas após uma parada prolongada.

### Painel

Abra uma conversa, configure **Regras** (`palavra-chave => resposta`) e as instruções, salve e ative **IA: On**. O trigger do banco coloca mensagens recebidas na fila; o worker responde mesmo que o atendente feche o painel. Respostas automáticas são deduplicadas por mensagem, processadas com lock concorrente e tentadas novamente em caso de falha transitória. Após cinco tentativas, o job fica com status `failed` em `ai_reply_jobs`.

As chaves salvas na Central de IA do navegador continuam servindo os relatórios e a conversa direta com a IA, mas não são usadas pela automação de atendimento. Para essa automação, o provedor e a chave vêm do ambiente do worker. O histórico recente (até 12 mensagens) é enviado ao provedor de IA configurado para gerar a resposta.