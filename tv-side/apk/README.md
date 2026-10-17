# 辅助 APK

`cecbridge.apk` 是已经编译好的 **debug 签名** 版本，方便直接 `adb install` 试用。
长期使用建议用自己的 key 重新签名。

## 源码

- `AndroidManifest.xml`
- `res/values/strings.xml`
- `smali/io/github/cecbridge/*.smali`

## 构建思路

这个 APK 很小，只有四个类，没有第三方依赖：

1. 用 `smali` 把 `smali/` 汇编成 `classes.dex`；
2. 用 `aapt` 以 `AndroidManifest.xml` + `res/` 打包，`classes.dex` 放在 APK 根目录；
3. 用 `apksigner`（或 `jarsigner`）用自己的 key 签名。

示例（路径按本机 SDK 调整）：

```sh
smali assemble smali -o classes.dex
aapt package -f -M AndroidManifest.xml -S res -I "$ANDROID_JAR" -F unsigned.apk
aapt add unsigned.apk classes.dex
apksigner sign --ks my-release.keystore --out cecbridge.apk unsigned.apk
```

仓库不包含任何 keystore。`cecbridge.apk` 使用 Android 默认 debug key 签名，
只适合测试；如果要覆盖安装自己的签名版本，先卸载旧包。
