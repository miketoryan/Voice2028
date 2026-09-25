from pathlib import Path

# iOS must use Apple's native Keychain backend, not the generic Unix/Linux
# Secret Service backend. The upstream target expression currently includes
# iOS in the Linux-native keyring dependency because iOS is Unix.
cargo = Path("src-tauri/Cargo.toml")
text = cargo.read_text()

old_apple = """[target.'cfg(target_os = "macos")'.dependencies.keyring]
version = "3.6.3"
default-features = false
features = ["apple-native"]
"""
new_apple = """[target.'cfg(any(target_os = "macos", target_os = "ios"))'.dependencies.keyring]
version = "3.6.3"
default-features = false
features = ["apple-native"]
"""
if old_apple not in text:
    raise SystemExit("Apple keyring dependency anchor missing")
text = text.replace(old_apple, new_apple, 1)

old_unix = """[target.'cfg(all(unix, not(target_os = "macos"), not(target_os = "android")))'.dependencies.keyring]
version = "3.6.3"
default-features = false
features = ["linux-native-sync-persistent", "crypto-rust"]
"""
new_unix = """[target.'cfg(all(unix, not(any(target_os = "macos", target_os = "android", target_os = "ios"))))'.dependencies.keyring]
version = "3.6.3"
default-features = false
features = ["linux-native-sync-persistent", "crypto-rust"]
"""
if old_unix not in text:
    raise SystemExit("generic Unix keyring dependency anchor missing")
text = text.replace(old_unix, new_unix, 1)
cargo.write_text(text)

# Reuse the existing Apple single-item credential-vault format on iOS.
# This persists channel cards, ordering, active providers and model settings
# across process death without writing secrets to a plaintext app file.
vault = Path("src-tauri/src/persistence/credentials.rs")
text = vault.read_text()

old_load = """        cfg!(target_os = "macos"),
"""
new_load = """        cfg!(any(target_os = "macos", target_os = "ios")),
"""
if old_load not in text:
    raise SystemExit("keyring consolidation anchor missing")
text = text.replace(old_load, new_load, 1)

old_save_cfg = """    #[cfg(target_os = "macos")]
    {
        let json = serde_json::to_string(&cleaned).context("encode credentials failed")?;
"""
new_save_cfg = """    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        let json = serde_json::to_string(&cleaned).context("encode credentials failed")?;
"""
if old_save_cfg not in text:
    raise SystemExit("Apple credential save branch anchor missing")
text = text.replace(old_save_cfg, new_save_cfg, 1)

old_generic_cfg = """    #[cfg(not(any(target_os = "android", target_os = "macos")))]
    {
"""
new_generic_cfg = """    #[cfg(not(any(target_os = "android", target_os = "macos", target_os = "ios")))]
    {
"""
# Only replace the save_credentials generic write branch. The first occurrence
# can be another helper, so locate it after save_credentials().
save_pos = text.find("fn save_credentials(root: &CredsRoot)")
if save_pos < 0:
    raise SystemExit("save_credentials missing")
generic_pos = text.find(old_generic_cfg, save_pos)
if generic_pos < 0:
    raise SystemExit("generic credential save branch anchor missing")
text = text[:generic_pos] + text[generic_pos:].replace(old_generic_cfg, new_generic_cfg, 1)
vault.write_text(text)

# Overview status must treat the ChatGPT OAuth ASR channel as configured when
# the same shared ChatGPT/Codex OAuth credential used by the runtime is valid.
commands = Path("src-tauri/src/commands/credentials.rs")
text = commands.read_text()
old_status = """    let asr_configured = openless_core::provider_rules::asr_configured(
        &active_asr_provider,
        &configuration,
        local_asr_configured(&active_asr_provider, model_store),
    );
"""
new_status = """    let asr_configured = if active_asr_provider == "chatgpt_oauth" {
        CodexOAuthCredentials::load_default().is_ok()
    } else {
        openless_core::provider_rules::asr_configured(
            &active_asr_provider,
            &configuration,
            local_asr_configured(&active_asr_provider, model_store),
        )
    };
"""
if old_status not in text:
    raise SystemExit("Overview ASR configured anchor missing")
text = text.replace(old_status, new_status, 1)
commands.write_text(text)

# Build-time contract checks.
cargo_text = cargo.read_text()
vault_text = vault.read_text()
commands_text = commands.read_text()
for expected in (
    'cfg(any(target_os = "macos", target_os = "ios"))',
    'not(any(target_os = "macos", target_os = "android", target_os = "ios"))',
):
    if expected not in cargo_text:
        raise SystemExit(f"iOS Apple Keychain Cargo patch missing: {expected}")
if 'cfg!(any(target_os = "macos", target_os = "ios"))' not in vault_text:
    raise SystemExit("iOS credential load is not using Apple single-item storage")
if '#[cfg(any(target_os = "macos", target_os = "ios"))]' not in vault_text:
    raise SystemExit("iOS credential save is not using Apple single-item storage")
if 'active_asr_provider == "chatgpt_oauth"' not in commands_text:
    raise SystemExit("Overview does not recognize GPT OAuth ASR")
