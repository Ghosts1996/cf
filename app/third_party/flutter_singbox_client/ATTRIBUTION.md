# Attribution

## sing-box-for-android

The Android native layer of this SDK is based on and inspired by
[sing-box-for-android](https://github.com/SagerNet/sing-box-for-android),
the official Android client for the Sing-box proxy platform.

The service lifecycle, network monitor implementation, `PlatformInterface`
integration, and `CommandClient`/`CommandServer` wiring in this SDK follow
the patterns established in that project.

**Project:** https://github.com/SagerNet/sing-box-for-android  
**License:** [GPL-3.0](https://github.com/SagerNet/sing-box-for-android/blob/main/LICENSE)

---

## Sing-box

This SDK embeds the [Sing-box](https://github.com/SagerNet/sing-box) proxy
platform as a prebuilt gomobile AAR (`libbox.aar`). Sing-box is the Go-based
proxy core that powers all VPN and proxy functionality exposed by this SDK.

**Project:** https://github.com/SagerNet/sing-box  
**License:** [GPL-3.0](https://github.com/SagerNet/sing-box/blob/dev-next/LICENSE)

---

*flutter_singbox_client is an independent Flutter plugin and is not affiliated
with or endorsed by the SagerNet project.*
