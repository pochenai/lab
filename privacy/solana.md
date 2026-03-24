## Confidentiality (Data Hidden, Identity Visible)
- [Confidential Transfer](https://solana.com/docs/tokens/extensions/confidential-transfer)
    - [Example](https://github.com/solana-developers/Confidential-Balances-Sample/tree/main)

## Anonymity (Data Visible, Identity Hidden)
- [Noctura](https://noc-tura.io/whitepaper.pdf)
    - compliance: policy controls (dual-control, limits), scoped view access for finance/compliance, and audit tokens for regulators/partners
    - Compliance UX: Threshold Prompts, Geofencing, KYC Pointers
        • Threshold prompts: Client checks soft/hard thresholds (e.g., value > regional cap). UI
        suggests creating an Audit Token or performing KYC when needed
        • Geo-fencing: Wallet disables Shielded Mode in restricted jurisdictions based on IP + KYC
        country (defense-in-depth); transparent mode remains unaffected
        • KYC pointers: For custodial ramps/exchanges, wallet can attach a KYC hash pointer
        within an Audit Token—verifiable by the partner without exposing identity data in-wallet
        • Travel-Rule adapters: Optional integration paths to providers (e.g., Notabene/OpenVASPstyle) triggered only for applicable flows
    - Noctura's ZK-native unlinkability avoids mixer heuristics and supports compliance-ready attestations

## Fully private (Data Hidden, Identity Hidden)
- [Contra payment channel](https://github.com/solana-foundation/contra)
- [magicblock](https://docs.magicblock.gg/pages/private-ephemeral-rollups-pers/introduction/onchain-privacy)


## References
- [Privacy on Solana](https://xbjpr0reg4kgflon.public.blob.vercel-storage.com/reports/Privacy%20on%20Solana%20for%20the%20Modern%20Enterprise.pdf)
