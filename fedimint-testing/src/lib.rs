use std::collections::HashSet;
use std::fmt::Debug;
use std::future::Future;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use async_trait::async_trait;
use fedimint_core::config::{ClientModuleConfig, ConfigGenParams, ServerModuleConfig};
use fedimint_core::core::{ModuleInstanceId, LEGACY_HARDCODED_INSTANCE_ID_WALLET};
use fedimint_core::db::mem_impl::MemDatabase;
use fedimint_core::db::{Database, ModuleDatabaseTransaction};
use fedimint_core::module::interconnect::ModuleInterconect;
use fedimint_core::module::registry::ModuleDecoderRegistry;
use fedimint_core::module::{
    ApiError, CommonModuleGen, InputMeta, ModuleCommon, ModuleError, ServerModuleGen,
    TransactionItemAmount,
};
use fedimint_core::{OutPoint, PeerId, ServerModule};

pub mod btc;
pub mod ln;

#[derive(Debug)]
pub struct FakeFed<Module> {
    pub members: Vec<(PeerId, Module, Database, ModuleInstanceId)>,
    client_cfg: ClientModuleConfig,
    block_height: Arc<std::sync::atomic::AtomicU64>,
}

// TODO: probably remove after modularization
#[derive(Debug, PartialEq, Eq)]
pub struct TestInputMeta {
    pub amount: TransactionItemAmount,
    pub keys: Vec<secp256k1_zkp::XOnlyPublicKey>,
}

impl<Module> FakeFed<Module>
where
    Module: ServerModule + 'static + Send + Sync,
{
    pub async fn new<ConfGen, F, FF>(
        members: usize,
        constructor: F,
        params: &ConfigGenParams,
        conf_gen: &ConfGen,
        module_instance_id: ModuleInstanceId,
    ) -> anyhow::Result<FakeFed<Module>>
    where
        ConfGen: ServerModuleGen,
        F: Fn(ServerModuleConfig, Database) -> FF,
        FF: Future<Output = anyhow::Result<Module>>,
    {
        let peers = (0..members)
            .map(|idx| PeerId::from(idx as u16))
            .collect::<Vec<_>>();
        let server_cfg = conf_gen.trusted_dealer_gen(&peers, params);
        let consensus_cfg = server_cfg[&PeerId::from(0)].consensus.value().clone();
        let cfg_response = conf_gen.to_config_response(consensus_cfg)?;

        let mut members = vec![];
        for (peer, cfg) in server_cfg {
            let db = Database::new(
                MemDatabase::new(),
                ModuleDecoderRegistry::from_iter([(
                    module_instance_id,
                    <ConfGen as ServerModuleGen>::Common::decoder(),
                )]),
            );
            let member = constructor(cfg, db.clone()).await?;
            members.push((peer, member, db, module_instance_id));
        }

        Ok(FakeFed {
            members,
            client_cfg: cfg_response.client,
            block_height: Arc::new(AtomicU64::new(0)),
        })
    }

    pub fn set_block_height(&self, bh: u64) {
        self.block_height.store(bh, Ordering::Relaxed);
    }

    pub async fn verify_input(
        &self,
        input: &<Module::Common as ModuleCommon>::Input,
    ) -> Result<TestInputMeta, ModuleError> {
        let fake_ic = FakeInterconnect::new_block_height_responder(self.block_height.clone());

        async fn member_validate<M: ServerModule>(
            member: &M,
            dbtx: &mut ModuleDatabaseTransaction<'_, ModuleInstanceId>,
            fake_ic: &FakeInterconnect,
            input: &<M::Common as ModuleCommon>::Input,
        ) -> Result<TestInputMeta, ModuleError> {
            let cache = member.build_verification_cache(std::iter::once(input));
            let InputMeta {
                amount,
                puk_keys: pub_keys,
            } = member.validate_input(fake_ic, dbtx, &cache, input).await?;
            Ok(TestInputMeta {
                amount,
                keys: pub_keys,
            })
        }

        let mut results = vec![];
        for (_, member, db, module_instance_id) in &self.members {
            let mut dbtx = db.begin_transaction().await;
            results.push(
                member_validate(
                    member,
                    &mut dbtx.with_module_prefix(*module_instance_id),
                    &fake_ic,
                    input,
                )
                .await,
            );
            dbtx.commit_tx().await;
        }

        assert_all_equal_result(results.into_iter())
    }

    pub async fn verify_output(&self, output: &<Module::Common as ModuleCommon>::Output) -> bool {
        let mut results = Vec::new();
        for (_, member, db, module_instance_id) in self.members.iter() {
            results.push(
                member
                    .validate_output(
                        &mut db
                            .begin_transaction()
                            .await
                            .with_module_prefix(*module_instance_id),
                        output,
                    )
                    .await
                    .is_err(),
            );
        }
        assert_all_equal(results.into_iter())
    }

    // TODO: add expected result to inputs/outputs
    pub async fn consensus_round(
        &mut self,
        inputs: &[<Module::Common as ModuleCommon>::Input],
        outputs: &[(OutPoint, <Module::Common as ModuleCommon>::Output)],
    ) where
        <<Module as ServerModule>::Common as ModuleCommon>::Input: Send + Sync + Eq,
    {
        let fake_ic = FakeInterconnect::new_block_height_responder(self.block_height.clone());
        // TODO: only include some of the proposals for realism
        let mut consensus = vec![];
        for (id, member, db, module_instance_id) in &mut self.members {
            consensus.extend(
                member
                    .consensus_proposal(
                        &mut db
                            .begin_transaction()
                            .await
                            .with_module_prefix(*module_instance_id),
                    )
                    .await
                    .into_items()
                    .into_iter()
                    .map(|ci| (*id, ci)),
            );
        }

        let peers: HashSet<PeerId> = self.members.iter().map(|p| p.0).collect();
        for (_peer, member, db, module_instance_id) in &mut self.members {
            let database = db as &mut Database;
            let mut dbtx = database.begin_transaction().await;
            {
                let mut module_dbtx = dbtx.with_module_prefix(*module_instance_id);

                member
                    .begin_consensus_epoch(&mut module_dbtx, consensus.clone())
                    .await;

                let cache = member.build_verification_cache(inputs.iter());
                for input in inputs {
                    member
                        .apply_input(&fake_ic, &mut module_dbtx, input, &cache)
                        .await
                        .expect("Faulty input");
                }

                for (out_point, output) in outputs {
                    member
                        .apply_output(&mut module_dbtx, output, *out_point)
                        .await
                        .expect("Faulty output");
                }

                member.end_consensus_epoch(&peers, &mut module_dbtx).await;
            }

            dbtx.commit_tx().await;
        }
    }

    pub async fn output_outcome(
        &self,
        out_point: OutPoint,
    ) -> Option<<Module::Common as ModuleCommon>::OutputOutcome>
    where
        <<Module as ServerModule>::Common as ModuleCommon>::OutputOutcome: Eq,
    {
        // Since every member is in the same epoch they should have the same internal
        // state, even in terms of outcomes. This may change later once
        // end_consensus_epoch is pulled out of the main consensus loop into
        // another thread to optimize latency. This test will probably fail
        // then.
        let mut results = Vec::new();
        for (_, member, db, module_instance_id) in self.members.iter() {
            results.push(
                member
                    .output_status(
                        &mut db
                            .begin_transaction()
                            .await
                            .with_module_prefix(*module_instance_id),
                        out_point,
                    )
                    .await,
            );
        }
        assert_all_equal(results.into_iter())
    }

    pub async fn generate_fake_utxo(&mut self) {
        for (_, _, db, module_instance_id) in &mut self.members {
            let mut dbtx = db.begin_transaction().await;
            let out_point = bitcoin::OutPoint::default();
            let tweak = [42; 32];
            let utxo = fedimint_wallet_client::SpendableUTXO {
                tweak,
                amount: bitcoin::Amount::from_sat(48000),
            };

            {
                let mut module_dbtx = dbtx.with_module_prefix(*module_instance_id);
                module_dbtx
                    .insert_entry(&fedimint_wallet_client::db::UTXOKey(out_point), &utxo)
                    .await;

                module_dbtx
                    .insert_entry(
                        &fedimint_wallet_client::db::RoundConsensusKey,
                        &fedimint_wallet_client::RoundConsensus {
                            block_height: 0,
                            fee_rate: fedimint_core::Feerate { sats_per_kvb: 0 },
                            randomness_beacon: tweak,
                        },
                    )
                    .await;
            }

            dbtx.commit_tx().await;
        }
    }

    pub fn client_cfg(&self) -> &ClientModuleConfig {
        &self.client_cfg
    }

    pub fn client_cfg_typed<T: serde::de::DeserializeOwned>(&self) -> anyhow::Result<T> {
        Ok(serde_json::from_value(self.client_cfg.value().clone())?)
    }

    pub async fn fetch_from_all<'a: 'b, 'b, O, F, Fut>(&'a mut self, fetch: F) -> O
    where
        O: Debug + Eq + Send,
        F: Fn(&'b mut Module, &'b mut Database, &'b ModuleInstanceId) -> Fut,
        Fut: futures::Future<Output = O> + Send,
    {
        let mut results = Vec::new();
        for (_, member, db, module_instance_id) in self.members.iter_mut() {
            results.push(fetch(member, db, module_instance_id).await);
        }
        assert_all_equal(results.into_iter())
    }
}

fn assert_all_equal<I>(mut iter: I) -> I::Item
where
    I: Iterator,
    I::Item: Eq + Debug,
{
    let first = iter.next().expect("empty iterator");
    for item in iter {
        assert_eq!(first, item);
    }
    first
}

/// Make sure all elements are equal for `Result<O, E>`
///
/// For errors their conversion to `String` via `Debug` is used to avoid
/// `E : Eq`.
fn assert_all_equal_result<I, O, E>(mut iter: I) -> I::Item
where
    I: Iterator<Item = Result<O, E>>,
    O: Eq + Debug,
    E: Debug,
{
    let first = iter.next().expect("empty iterator");

    match &first {
        Ok(first) => {
            for item in iter {
                match item {
                    Ok(item) => {
                        assert_eq!(first, &item);
                    }
                    Err(e) => {
                        panic!("Assertion error: Ok({first:?}) != Err({e:?})");
                    }
                }
            }
        }
        Err(first) => {
            let first = format!("{first:?}");

            for item in iter {
                match item {
                    Ok(o) => {
                        panic!("Assertion error: Err({first}) != Ok({o:?})");
                    }
                    Err(e) => {
                        assert_eq!(first, format!("{e:?}"));
                    }
                }
            }
        }
    }

    first
}

struct FakeInterconnect(
    Box<
        dyn Fn(ModuleInstanceId, String, serde_json::Value) -> Result<serde_json::Value, ApiError>
            + Sync
            + Send,
    >,
);

impl FakeInterconnect {
    fn new_block_height_responder(bh: Arc<AtomicU64>) -> FakeInterconnect {
        FakeInterconnect(Box::new(move |module, path, _data| {
            assert_eq!(module, LEGACY_HARDCODED_INSTANCE_ID_WALLET);
            assert_eq!(path, "/block_height");

            let height = bh.load(Ordering::Relaxed);
            Ok(serde_json::to_value(height).expect("encoding error"))
        }))
    }
}

#[async_trait]
impl ModuleInterconect for FakeInterconnect {
    async fn call(
        &self,
        module_id: ModuleInstanceId,
        path: String,
        data: serde_json::Value,
    ) -> Result<serde_json::Value, ApiError> {
        (self.0)(module_id, path, data)
    }
}
