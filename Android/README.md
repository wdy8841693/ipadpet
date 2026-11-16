# 鲸鱼娘 DSH · Android 版 🐋

iPad 版（`WhalePet/`，SwiftUI 之外的纯 UIKit + SpriteKit）的 Android 重制版：
**同一套立绘、同一套数值/状态机、同一套台词、同一个桥接协议**，
只是把 SpriteKit 换成 `SurfaceView` + `Canvas`，把 AVAudioEngine/AVSpeechSynthesizer 换成
`AudioRecord`/`TextToSpeech`，把 URLSessionWebSocketTask 换成 OkHttp WebSocket。

- 包名：`com.dywu.whalepet`　版本：`1.3.0-android.1`
- minSdk 21（Android 5.0）/ targetSdk 33（Android 13）
- 纯 Java，**不依赖 AndroidX**，全部绘制自己画：装到任何设备上都是同一个样子
- 产物：`build/whalepet-android.apk`（debug 签名，约 2.3 MB）

## 与 iOS 版的对应关系

| 能力 | iOS | Android |
|---|---|---|
| 立绘渲染 | SpriteKit（`SKTexture` + `SKAction`） | `SurfaceView` 渲染线程 + `Canvas`，30fps，程序化变换 |
| 行为状态机 | `PetBrain`（纯逻辑） | `PetBrain`（逐行移植，纯 Java） |
| 数值/存档 | `PetVitals` / JSON 到 Application Support | `PetVitals` / JSON 到 `filesDir/whalepet-save.json` |
| 台词库 | `Dialogue` | `Dialogue`（同样按状态 + 数值挑句、避免连续重复） |
| 语音上行 | `AVAudioEngine` → 16k PCM | `AudioRecord` → 线性重采样到 16k PCM |
| 播报 | `AVSpeechSynthesizer` | 系统 `TextToSpeech`（`Locale.SIMPLIFIED_CHINESE`） |
| 通道 | `/api/audio` WebSocket（hello + 二进制 PCM + 控制文本） | 同左，OkHttp WebSocket |
| 权限存储 | Keychain | 私有 `SharedPreferences`（未 root 的设备其它应用读不到） |

代码结构：

```
Android/
├── app/src/main/
│   ├── java/com/dywu/whalepet/
│   │   ├── MainActivity.java        # 全屏容器 + 改名/服务器设置弹窗 + 权限
│   │   ├── pet/                     # PetState / PetVitals / PetBrain / Dialogue / PetStore
│   │   ├── net/                     # ServerSettings / DSHClient（HTTP + WebSocket）
│   │   ├── voice/                   # VoiceController（采集 / 重采样 / TTS / 状态机）
│   │   └── ui/                      # PetView（场景）/ Hud / SpeechBubble
│   ├── assets/sprites/              # 10 张立绘 + 背景 + 特效（与 iOS 同一批 PNG）
│   └── res/mipmap-*/                # 启动图标（由 tools/make_icons.py 生成）
├── libs/                            # okhttp 3.12.13 + okio 1.17.6（脚本构建用）
├── tools/make_icons.py              # 1024 图标 → 各密度 mipmap（纯标准库）
├── build-apk.sh                     # 不依赖 Gradle 的构建脚本
└── build.gradle / settings.gradle   # Android Studio 用
```

## 构建

### 方式 A：命令行（本项目实际使用的方式，不需要 Gradle）

只需要 JDK 17 + Android SDK 的 build-tools 与 platform：

```bash
# 三个路径按自己机器改；装过 Android Studio 的可以直接指到 SDK 目录
export JDK_HOME=/path/to/jdk-17
export BT_DIR=/path/to/android-sdk/build-tools/34.0.0
export PLATFORM_JAR=/path/to/android-sdk/platforms/android-33/android.jar

cd Android
bash build-apk.sh          # → build/whalepet-android.apk
```

脚本做的事：`aapt2 compile/link` → `javac` → `d8` → 塞 `classes.dex` → `zipalign` → `apksigner`，
首次运行会自动生成 `keystore/debug.keystore`。

> Windows 上如果仓库在网络盘（UNC 路径），请在本地目录里执行（`cd C:/xxx && bash //nas/.../build-apk.sh`），
> 因为 `cmd.exe` 不支持 UNC 作为工作目录，`d8.bat` / `apksigner.bat` 会回退到 `C:\Windows`。

### 方式 B：Android Studio

`File → Open` 选 `Android/`，等 Gradle 同步完直接 Run。
（`app/build.gradle` 用的是 AGP 7.4.2；若要升 AGP 8，需删掉 `AndroidManifest.xml` 里的
`package="com.dywu.whalepet"` —— 那是给 `build-apk.sh` 的 aapt2 用的。）

### 安装

```bash
adb install -r Android/build/whalepet-android.apk
```

或把 APK 拷到手机上点开安装（需要允许「安装未知来源应用」）。

## 首次使用

1. 启动后点右下 **⚙️ 设置**，填：
   - 服务器地址：`http://<运行 DSH 的机器 IP>:8787`
   - 访问令牌：DSH 机器上 `cat ~/.dsh/whalepet/ipad-token` 的内容
2. 点「保存并测试」，出现「连接成功」即放行麦克风权限。
3. 说「**小鲸小鲸**」唤醒，听到「我在」后说指令；也可以直接点 🎙️ 手动开始一次聆听。

离线时摸摸头、投喂、玩耍、睡觉都照常可用，数值与存档都在本地。

## Android 侧的实现要点（踩过的坑）

- **`android.jar` 不能当 `-bootclasspath` 用**：它没有 `java.lang.invoke.LambdaMetafactory`，
  lambda / 方法引用会全部编译失败。放到 `-classpath` 上、让 `d8 --lib android.jar` 负责脱糖，
  与 AGP 的做法一致。
- **d8 不吃裸目录**：先 `jar cf classes.jar -C classes .` 再喂给 d8，否则报
  `Unsupported source file type`（这个报错其实是"文件不存在"的伪装）。
- **坐标体系**：模型沿用 iOS 的"原点左下、y 向上"，绘制时统一 `devY = sceneH - y`；
  所有长度单位是 dp（等价于 iOS 的 point），绘制前 `canvas.scale(density, density)`。
  立绘锚点在**底边中心**（= 脚底），旋转取负角度以对齐 SpriteKit 的正向。
- **背压**：WebSocket 发送按"时间 × 32KB/s"估算网络排空量，队列超过 1.5MB 直接丢帧
  （语音实时性 > 完整性），与 iOS 版同一策略。
- **播报期间闭麦**：`playback_start` → 暂停 `AudioRecord` → TTS 播完 `playback_end` → 恢复采集，
  避免拾到自己的声音触发唤醒。
- **断线重连**：1s/2s/4s/8s/16s/30s 指数退避，最多 10 次；鉴权失败（401/403）不重试，直接提示令牌无效。

## 已知限制

- 只在编译层面验证过（`aapt2` + `javac` + `d8` + `apksigner` 全绿、APK 校验通过），
  **没有在真机/模拟器上跑过**：本机没有 Android SDK 模拟器镜像。首次上机请留意
  Logcat 里的 `WhalePet*` 标签。
- 语音唤醒/ASR 全部在服务器侧（与 iPad 版一致），手机端不做离线识别；
  TTS 依赖系统自带中文语音包（部分精简 ROM 需要先在系统设置里装「中文语音」）。
- 应用图标是 iPad 版 1024 图标的降采样版本，没有做自适应图标（`ic_launcher_foreground`）。
- 令牌存在 `SharedPreferences`（Android 没有 Keychain）。需要更强保护可接
  `androidx.security:security-crypto`。
