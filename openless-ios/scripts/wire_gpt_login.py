from pathlib import Path

# Rust: expose two iOS-only Tauri commands to the OpenLess WebView.
p = Path("src-tauri/src/lib.rs")
text = p.read_text()

module_anchor = '#[cfg(target_os = "ios")]\nmod chatgpt_asr;\n'
module_addition = (
    '#[cfg(target_os = "ios")]\nmod chatgpt_asr;\n'
    '#[cfg(target_os = "ios")]\nmod chatgpt_bridge;\n'
)
if 'mod chatgpt_bridge;' not in text:
    if module_anchor not in text:
        raise SystemExit("chatgpt_asr module anchor missing")
    text = text.replace(module_anchor, module_addition, 1)

mobile_pos = text.find("macro_rules! app_invoke_handler_mobile")
if mobile_pos < 0:
    raise SystemExit("mobile invoke handler missing")

if "chatgpt_oauth_begin" not in text[mobile_pos:]:
    first_command = '            $crate::commands::get_startup_snapshot,\n'
    first_pos = text.find(first_command, mobile_pos)
    if first_pos < 0:
        raise SystemExit("mobile invoke command anchor missing")
    commands = (
        '            $crate::commands::get_startup_snapshot,\n'
        '            #[cfg(target_os = "ios")]\n'
        '            $crate::chatgpt_bridge::chatgpt_oauth_begin,\n'
        '            #[cfg(target_os = "ios")]\n'
        '            $crate::chatgpt_bridge::chatgpt_oauth_status,\n'
    )
    text = text[:first_pos] + text[first_pos:].replace(first_command, commands, 1)

p.write_text(text)

# React: login lives inside OpenLess' own channel UI.
p = Path("src/pages/settings/ProvidersSection.tsx")
text = p.read_text()

import_anchor = "import { BailianProtocolField } from './BailianProtocolField';\n"
login_import = "import { ChatGPTLoginControl } from './ChatGPTLoginControl';\n"
if login_import not in text:
    if import_anchor not in text:
        raise SystemExit("ProvidersSection import anchor missing")
    text = text.replace(import_anchor, import_anchor + login_import, 1)

llm_old = """        {codexOAuthSelected ? (
          <div
            style={{
              fontSize: 11.5,
              color: 'var(--ol-ink-4)',
              lineHeight: 1.6,
              margin: '2px 0 10px',
            }}
          >
            {t('settings.providers.codexOAuthNotice')}
          </div>
        ) : (
"""
llm_new = """        {codexOAuthSelected ? (
          <div
            style={{
              fontSize: 11.5,
              color: 'var(--ol-ink-4)',
              lineHeight: 1.6,
              margin: '2px 0 10px',
            }}
          >
            <ChatGPTLoginControl />
            {t('settings.providers.codexOAuthNotice')}
          </div>
        ) : (
"""
if '<ChatGPTLoginControl />' not in text:
    if llm_old not in text:
        raise SystemExit("LLM OAuth render block missing")
    text = text.replace(llm_old, llm_new, 1)

asr_old = """  if (descriptor?.authRequirement === 'o_auth') {
            return (
              <div style={{ fontSize: 11.5, color: 'var(--ol-ink-4)', lineHeight: 1.6 }}>
                {t('settings.providers.codexOAuthNotice')}
              </div>
            );
          }

"""
asr_new = """  if (descriptor?.authRequirement === 'o_auth') {
            return (
              <div>
                <ChatGPTLoginControl />
                <div style={{ fontSize: 11.5, color: 'var(--ol-ink-4)', lineHeight: 1.6 }}>
                  {t('settings.providers.codexOAuthNotice')}
                </div>
              </div>
            );
          }

"""
if asr_old in text:
    text = text.replace(asr_old, asr_new, 1)

p.write_text(text)

if "chatgpt_oauth_begin" not in Path("src-tauri/src/lib.rs").read_text():
    raise SystemExit("GPT OAuth begin command was not wired")
if "ChatGPTLoginControl" not in p.read_text():
    raise SystemExit("GPT login control was not wired")
