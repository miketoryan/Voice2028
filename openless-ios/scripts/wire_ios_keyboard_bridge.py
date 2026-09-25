from pathlib import Path

# Register the iOS keyboard localhost bridge as an iOS-only Rust module.
p = Path("src-tauri/src/lib.rs")
text = p.read_text()

anchor = '#[cfg(target_os = "ios")]\nmod chatgpt_asr;\n'
addition = (
    '#[cfg(target_os = "ios")]\nmod chatgpt_asr;\n'
    '#[cfg(target_os = "ios")]\nmod ios_keyboard_bridge;\n'
)
if 'mod ios_keyboard_bridge;' not in text:
    if anchor not in text:
        raise SystemExit("chatgpt_asr module anchor missing")
    text = text.replace(anchor, addition, 1)

p.write_text(text)

# Start the bridge after Core is fully started so keyboard commands can call
# start_dictation/stop_dictation directly on the shared OpenLess backend.
p = Path("src-tauri/src/mobile_runtime.rs")
text = p.read_text()

anchor = """            let startup = tauri::async_runtime::block_on(core_backend.start())?;
            if !startup.backend.running {
                return Err("OpenLess Core did not reach the running state".into());
            }
"""
addition = """            let startup = tauri::async_runtime::block_on(core_backend.start())?;
            if !startup.backend.running {
                return Err("OpenLess Core did not reach the running state".into());
            }
            #[cfg(target_os = "ios")]
            crate::ios_keyboard_bridge::start(Arc::clone(&core_backend));
"""
if 'ios_keyboard_bridge::start' not in text:
    if anchor not in text:
        raise SystemExit("mobile Core startup anchor missing")
    text = text.replace(anchor, addition, 1)

p.write_text(text)

if 'mod ios_keyboard_bridge;' not in Path("src-tauri/src/lib.rs").read_text():
    raise SystemExit("iOS keyboard bridge module was not registered")
if 'ios_keyboard_bridge::start' not in Path("src-tauri/src/mobile_runtime.rs").read_text():
    raise SystemExit("iOS keyboard bridge was not started")
