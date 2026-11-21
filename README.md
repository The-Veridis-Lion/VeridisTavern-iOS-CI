# VeridisTavern for iOS

This fork packages iOS Simulator builds of [TauriTavern at commit `039a2784`](https://github.com/Darkatse/TauriTavern/tree/039a278448df37ac18f23d7015c06213bc6fcb36). The source for each build is that public commit plus the corresponding patch below. The upstream [GNU AGPL v3 license](LICENSE) applies.

| Variant | Changes | Patch SHA-256 |
| --- | --- | --- |
| [M1](patches/M1.patch) | Chat targeting, settings persistence, and request handling | `7b4b882dd47e5441b7171e82cee051f573e86d3b4d917db3c95d997dadd605a9` |
| [M2](patches/M2.patch) | M1 plus native persistence of the selected character chat | `b86beb0840dbb77561ae38309942daf55d303f8634beab380f09ea8e01e35af0` |
| [After](patches/After.patch) | M2 plus a Showdown block-scan optimization | `2fba8d0548715ee1c6522515294fcd8bd784b0125824393f8256f9cff727020e` |

In GitHub Actions, run **iOS Simulator build** and choose a variant. **After** is the default. The workflow uses GitHub's standard `xcode-27` arm64 runner with Xcode 27.2. The artifact `<variant>-iOS-Simulator` contains an unsigned arm64 Simulator application with the frontend bundled. It can be installed on an iOS Simulator on Apple silicon.
