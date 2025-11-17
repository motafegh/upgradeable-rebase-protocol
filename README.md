# Upgradeable Rebase Protocol

> **Status:** 🚧 Work in Progress - Converting immutable protocol to UUPS upgradeable

**Sister Project:** [cross-chain-rebasing-protocol](https://github.com/motafegh/cross-chain-rebasing-protocol) (immutable version)

## What's Different?

This project demonstrates the **same protocol** but with upgradeability using the UUPS proxy pattern.

### Comparison Table

| Feature | Immutable Version | Upgradeable Version |
|---------|------------------|---------------------|
| Trustlessness | ✅ Maximum | ⚠️ Depends on governance |
| Bug fixes | ❌ Impossible | ✅ Possible via upgrade |
| Gas cost | ✅ ~95k gas/transfer | ⚠️ ~98k gas/transfer (+3%) |
| Complexity | ✅ Simple | ⚠️ Complex storage rules |

## Progress Tracker

- [ ] Day 1: Convert RebaseToken to V1
- [ ] Day 2: Implement V2 with new features
- [ ] Day 3: Testing & Sepolia deployment
- [ ] Day 4: Documentation polish

---

*Last updated: [current date]*
