from pathlib import Path

p = Path("crates/openless-core/src/provider_resolution.rs")
text = p.read_text()

old = """    let provider_id = match credential_store.active_provider(slot).await {
        Ok(provider) if !provider.trim().is_empty() => provider,
        Ok(_) => preference_fallback.to_string(),
        Err(error) if error.code == BackendErrorCode::Unsupported => {
            preference_fallback.to_string()
        }
        Err(error) => return Err(error),
    };
"""

new = """    let provider_id = {
        #[cfg(target_os = "ios")]
        {
            if matches!(slot, ProviderSlot::Asr) {
                match credential_store.list_channels(ChannelKind::Asr).await {
                    Ok(channels) => {
                        if let Some(channel) = channels.into_iter().find(|channel| channel.enabled) {
                            channel.id
                        } else {
                            match credential_store.active_provider(slot).await {
                                Ok(provider) if !provider.trim().is_empty() => provider,
                                Ok(_) => preference_fallback.to_string(),
                                Err(error) if error.code == BackendErrorCode::Unsupported => {
                                    preference_fallback.to_string()
                                }
                                Err(error) => return Err(error),
                            }
                        }
                    }
                    Err(error) if error.code == BackendErrorCode::Unsupported => {
                        match credential_store.active_provider(slot).await {
                            Ok(provider) if !provider.trim().is_empty() => provider,
                            Ok(_) => preference_fallback.to_string(),
                            Err(error) if error.code == BackendErrorCode::Unsupported => {
                                preference_fallback.to_string()
                            }
                            Err(error) => return Err(error),
                        }
                    }
                    Err(error) => return Err(error),
                }
            } else {
                match credential_store.active_provider(slot).await {
                    Ok(provider) if !provider.trim().is_empty() => provider,
                    Ok(_) => preference_fallback.to_string(),
                    Err(error) if error.code == BackendErrorCode::Unsupported => {
                        preference_fallback.to_string()
                    }
                    Err(error) => return Err(error),
                }
            }
        }

        #[cfg(not(target_os = "ios"))]
        {
            match credential_store.active_provider(slot).await {
                Ok(provider) if !provider.trim().is_empty() => provider,
                Ok(_) => preference_fallback.to_string(),
                Err(error) if error.code == BackendErrorCode::Unsupported => {
                    preference_fallback.to_string()
                }
                Err(error) => return Err(error),
            }
        }
    };
"""

if old not in text:
    raise SystemExit("provider resolution anchor missing")

text = text.replace(old, new, 1)
p.write_text(text)

if 'channels.into_iter().find(|channel| channel.enabled)' not in p.read_text():
    raise SystemExit("iOS ASR first-enabled routing was not wired")
