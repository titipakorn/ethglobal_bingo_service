// Allow `cargo stylus export-abi` to generate a main function.
#![cfg_attr(not(feature = "export-abi"), no_main)]
extern crate alloc;

// use alloy_sol_types::sol;
/// Import items from the SDK. The prelude contains common traits and macros.
use stylus_sdk::block;
use stylus_sdk::{alloy_primitives::U256, crypto, prelude::*};

// Define some persistent storage using the Solidity ABI.
// `Counter` will be the entrypoint.
sol_storage! {
    #[entrypoint]
    pub struct PureRandom {
        uint256 nonce;            // Incremental counter to ensure uniqueness
    }
}

// sol! {
//     event RandomEvent(uint256 timestamp, uint256 number, uint256 base_fee);
// }
/// Declare that `Counter` is a contract with the following external methods.
#[public]
impl PureRandom {
    /// Increments `number` and updates its value in storage.
    pub fn increment(&mut self) {
        let nonce = self.nonce.get();
        self.nonce.set(nonce + U256::from(1));
    }

    /// Gets the number from storage.
    pub fn nonce(&self) -> U256 {
        self.nonce.get()
    }

    pub fn generate(&mut self) -> U256 {
        let timestamp = U256::from(block::timestamp());
        U256::from_be_bytes(*crypto::keccak(timestamp.to_le_bytes::<32>()))
    }

    // pub fn random_range(&mut self, min: U256, max: U256) -> U256 {
    //     assert!(max > min, "Max must be greater than min");
    //     let rand = self.generate();
    //     min + (rand % (max - min + U256::from(1)))
    // }
}
