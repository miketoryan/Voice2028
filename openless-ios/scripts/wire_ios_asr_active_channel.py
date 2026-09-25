from pathlib import Path


p = Path("crates/openless-core/src/credentials.rs")
text = p.read_text()

# ChannelList's public contract is "the first enabled card is current". Keep
# the persisted active provider on exactly that same channel, including when a
# user upgrades from a stale legacy active provider that is no longer a card.
old_directory_reads = """    pub async fn list_channels(
        &self,
        kind: ChannelKind,
    ) -> Result<Vec<ChannelSummary>, BackendError> {
        Ok(self.store.load_metadata().await?.list_channels(kind))
    }

    pub async fn active_provider(&self, slot: ProviderSlot) -> Result<String, BackendError> {
        Ok(self.store.load_metadata().await?.active_provider(slot))
    }
"""

new_directory_reads = """    pub async fn list_channels(
        &self,
        kind: ChannelKind,
    ) -> Result<Vec<ChannelSummary>, BackendError> {
        let _guard = self.mutation_gate.lock().await;
        let mut metadata = self.store.load_metadata().await?;
        let repaired = metadata.reconcile_active_provider(kind);
        let channels = metadata.list_channels(kind);
        if repaired {
            self.store.save_metadata(metadata).await?;
        }
        Ok(channels)
    }

    pub async fn active_provider(&self, slot: ProviderSlot) -> Result<String, BackendError> {
        let _guard = self.mutation_gate.lock().await;
        let mut metadata = self.store.load_metadata().await?;
        let repaired = match slot {
            ProviderSlot::Asr => metadata.reconcile_active_provider(ChannelKind::Asr),
            ProviderSlot::Llm => metadata.reconcile_active_provider(ChannelKind::Llm),
            ProviderSlot::Omni => false,
        };
        let active = metadata.active_provider(slot);
        if repaired {
            self.store.save_metadata(metadata).await?;
        }
        Ok(active)
    }
"""

if old_directory_reads not in text:
    raise SystemExit("credential directory read anchors missing")
text = text.replace(old_directory_reads, new_directory_reads, 1)

# The first channel must replace an unmanaged legacy fallback such as
# "volcengine". Otherwise the UI can label GPT current while active_providers
# still points at that fallback.
old_managed = """            || self
                .channels
                .get(&mutation_kind)
                .is_some_and(|channels| channels.iter().any(|channel| channel.id == active));
"""
new_managed = """            || self
                .channels
                .get(&mutation_kind)
                .is_none_or(|channels| channels.is_empty())
            || self
                .channels
                .get(&mutation_kind)
                .is_some_and(|channels| channels.iter().any(|channel| channel.id == active));
"""
if old_managed not in text:
    raise SystemExit("active channel ownership anchor missing")
text = text.replace(old_managed, new_managed, 1)

old_sync = """    fn sync_active(&mut self, kind: ChannelKind) {
        let slot = slot_for_kind(kind);
        let active = self
            .channels
            .get(&kind)
            .and_then(|channels| channels.iter().find(|channel| channel.enabled))
            .map(|channel| channel.id.clone())
            .unwrap_or_default();
        self.active_providers.insert(slot, active);
    }
"""
new_sync = """    fn canonical_active_provider(&self, kind: ChannelKind) -> String {
        self.channels
            .get(&kind)
            .and_then(|channels| channels.iter().find(|channel| channel.enabled))
            .map(|channel| channel.id.clone())
            .unwrap_or_default()
    }

    fn reconcile_active_provider(&mut self, kind: ChannelKind) -> bool {
        let slot = slot_for_kind(kind);
        let active = self.canonical_active_provider(kind);
        if self.active_providers.get(&slot) == Some(&active) {
            return false;
        }
        self.active_providers.insert(slot, active);
        self.revision = self.revision.saturating_add(1);
        true
    }

    fn sync_active(&mut self, kind: ChannelKind) {
        let slot = slot_for_kind(kind);
        let active = self.canonical_active_provider(kind);
        self.active_providers.insert(slot, active);
    }
"""
if old_sync not in text:
    raise SystemExit("active channel synchronization anchor missing")
text = text.replace(old_sync, new_sync, 1)

test_anchor = """    #[test]
    fn partial_reorder_preserves_unlisted_channel_order_and_blank_delete_is_safe() {
"""
test = """    #[test]
    fn first_channel_replaces_stale_legacy_active_provider() {
        let mut metadata = CredentialMetadata::from_parts(
            vec![],
            vec![],
            "volcengine",
            "",
            "",
            4,
        );

        let created = metadata
            .apply_channel_mutation(
                ChannelMutation::Create {
                    kind: ChannelKind::Asr,
                    provider_type: "chatgpt_oauth".to_string(),
                    name: "GPT Speech Recognition".to_string(),
                },
                |_| false,
            )
            .unwrap();

        assert_eq!(
            created,
            ChannelMutationResult::Created("chatgpt_oauth".to_string())
        );
        assert_eq!(
            metadata.active_provider(ProviderSlot::Asr),
            "chatgpt_oauth"
        );
    }

    #[tokio::test]
    async fn directory_repairs_stale_active_provider_to_first_enabled_channel() {
        let repository = std::sync::Arc::new(InMemoryCredentialStore::default());
        *repository.metadata.write().unwrap() = CredentialMetadata::from_parts(
            vec![
                summary("chatgpt_oauth", 0, true),
                summary("volcengine", 1, true),
            ],
            vec![],
            "volcengine",
            "",
            "",
            8,
        );
        let metadata_store: std::sync::Arc<dyn CredentialMetadataStore> = repository.clone();
        let directory = CredentialDirectory::new(metadata_store);

        let channels = directory.list_channels(ChannelKind::Asr).await.unwrap();
        assert_eq!(channels[0].id, "chatgpt_oauth");
        assert_eq!(
            directory.active_provider(ProviderSlot::Asr).await.unwrap(),
            "chatgpt_oauth"
        );
        assert_eq!(repository.load_metadata().await.unwrap().revision(), 9);
    }

    #[test]
    fn partial_reorder_preserves_unlisted_channel_order_and_blank_delete_is_safe() {
"""
if test_anchor not in text:
    raise SystemExit("credential tests anchor missing")
text = text.replace(test_anchor, test, 1)

p.write_text(text)

# Overview/status used to bypass CredentialDirectory and read the legacy Vault
# active value directly. Reconcile both channel slots before every status read
# so the overview, keyboard bridge and runtime provider all observe the same
# first-enabled Channel identity.
api_p = Path("crates/openless-core/src/api.rs")
api_text = api_p.read_text()

old_status = """    pub async fn get_credentials_status(&self) -> Result<CredentialsStatus, BackendError> {
        let status = self
            .deps
            .credential_store
            .status(self.get_preferences())
            .await?;
"""
new_status = """    pub async fn get_credentials_status(&self) -> Result<CredentialsStatus, BackendError> {
        // Status adapters read the persisted provider snapshot. Canonicalize it
        // through the same directory used by ChannelList and dictation routing
        // before exposing it to Overview.
        let _ = self
            .deps
            .credential_store
            .active_provider(ProviderSlot::Asr)
            .await?;
        let _ = self
            .deps
            .credential_store
            .active_provider(ProviderSlot::Llm)
            .await?;
        let status = self
            .deps
            .credential_store
            .status(self.get_preferences())
            .await?;
"""
if old_status not in api_text:
    raise SystemExit("get_credentials_status reconciliation anchor missing")
api_text = api_text.replace(old_status, new_status, 1)

old_refresh = """    async fn refresh_and_publish_credentials(&self) -> Result<CredentialsStatus, BackendError> {
        let status = self
            .deps
            .credential_store
            .status(self.get_preferences())
            .await?;
"""
new_refresh = """    async fn refresh_and_publish_credentials(&self) -> Result<CredentialsStatus, BackendError> {
        let _ = self
            .deps
            .credential_store
            .active_provider(ProviderSlot::Asr)
            .await?;
        let _ = self
            .deps
            .credential_store
            .active_provider(ProviderSlot::Llm)
            .await?;
        let status = self
            .deps
            .credential_store
            .status(self.get_preferences())
            .await?;
"""
if old_refresh not in api_text:
    raise SystemExit("refresh credential reconciliation anchor missing")
api_text = api_text.replace(old_refresh, new_refresh, 1)
api_p.write_text(api_text)

final = p.read_text()
for expected in (
    "first_channel_replaces_stale_legacy_active_provider",
    "directory_repairs_stale_active_provider_to_first_enabled_channel",
    "reconcile_active_provider",
):
    if expected not in final:
        raise SystemExit(f"canonical active channel patch missing: {expected}")

api_final = api_p.read_text()
if api_final.count(".active_provider(ProviderSlot::Asr)") < 2:
    raise SystemExit("credential status does not reconcile the active ASR channel")
