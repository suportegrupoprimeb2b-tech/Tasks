# Tasks

## Atendimento automático com IA

1. Se o banco já está configurado, execute no SQL Editor o bloco `conversation_ai_settings` e sua política RLS de `supabase_schema.sql`. Para uma configuração inicial, execute o arquivo completo.
2. Configure e salve uma API Key na Central de IA do painel.
3. Na aba **Automações**, crie um fluxo com comando (por exemplo, `/rastreio`), assunto permitido, mensagem inicial, instruções e respostas fixas opcionais.
4. Abra a conversa com o contato e escolha o fluxo no seletor. Enviar o comando exato, como `/rastreio`, ativa a IA nessa conversa e envia a mensagem inicial configurada; o comando em si não é enviado.
5. Também é possível ativar **IA: On** manualmente depois de escolher o fluxo. As mensagens recebidas serão respondidas apenas dentro do assunto do fluxo, com geração limitada a 400 tokens e resposta curta.
6. Para responder em segundo plano, rode o worker no servidor com `SUPABASE_SERVICE_ROLE_KEY` e a chave da IA no `.env`:
   `python chat_ai_worker.py`

Se o banco já está configurado, aplique os blocos `conversation_automations` e `automation_id` de `supabase_schema.sql` além da tabela/política `conversation_ai_settings`. Para uma configuração inicial, execute o arquivo completo.

As chaves de API permanecem no `localStorage` do navegador do atendente e não são gravadas no Supabase. A automação responde enquanto o atendente estiver com a sessão aberta e a conversa selecionada. Para funcionar em segundo plano, o worker usa a fila `ai_reply_jobs` e o trigger `enqueue_ai_reply_job_after_message_insert` do schema.