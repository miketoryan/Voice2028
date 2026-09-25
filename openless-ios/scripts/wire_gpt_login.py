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
if llm_old in text:
    text = text.replace(llm_old, llm_new, 1)
elif "codexOAuthSelected ? (" in text:
    llm_pos = text.find("codexOAuthSelected ? (")
    llm_end = text.find(") : (", llm_pos)
    llm_slice = text[llm_pos:llm_end if llm_end > llm_pos else len(text)]
    if "<ChatGPTLoginControl />" not in llm_slice:
        raise SystemExit("LLM OAuth branch exists but GPT login control was not inserted")

# ASR is a separate branch. Do not infer its state from whether the LLM branch
# already contains ChatGPTLoginControl.
asr_marker = "if (descriptor?.authRequirement === 'o_auth') {"
asr_pos = text.find(asr_marker, text.find("const defaultEndpoint = descriptor?.defaultEndpoint;", text.find("if (kind === 'llm')")))
none_pos = text.find("if (descriptor?.authRequirement === 'none') {", asr_pos)

if asr_pos < 0 or none_pos < 0:
    raise SystemExit("ASR OAuth branch missing")

asr_indent_start = text.rfind("\n", 0, asr_pos) + 1
asr_indent = text[asr_indent_start:asr_pos]
asr_new = f"""{asr_indent}if (descriptor?.authRequirement === 'o_auth') {{
{asr_indent}  return (
{asr_indent}    <div>
{asr_indent}      <ChatGPTLoginControl />
{asr_indent}      <div style={{{{ fontSize: 11.5, color: 'var(--ol-ink-4)', lineHeight: 1.6 }}}}>
{asr_indent}        {{t('settings.providers.codexOAuthNotice')}}
{asr_indent}      </div>
{asr_indent}    </div>
{asr_indent}  );
{asr_indent}}}

{asr_indent}"""

text = text[:asr_indent_start] + asr_new + text[none_pos:]

p.write_text(text)

if "chatgpt_oauth_begin" not in Path("src-tauri/src/lib.rs").read_text():
    raise SystemExit("GPT OAuth begin command was not wired")
final_text = p.read_text()
if "ChatGPTLoginControl" not in final_text:
    raise SystemExit("GPT login control was not wired")

asr_check_pos = final_text.find("if (descriptor?.authRequirement === 'o_auth') {", final_text.find("const defaultEndpoint = descriptor?.defaultEndpoint;", final_text.find("if (kind === 'llm')")))
asr_none_pos = final_text.find("if (descriptor?.authRequirement === 'none') {", asr_check_pos)
if asr_check_pos < 0 or asr_none_pos < 0:
    raise SystemExit("ASR OAuth verification range missing")
if "<ChatGPTLoginControl />" not in final_text[asr_check_pos:asr_none_pos]:
    raise SystemExit("ASR GPT login control was not wired")
