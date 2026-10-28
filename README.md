# TMMemberPatch

TM手游加速器（`com.TMSpeed.Lightning` 2.1.8 / 21801）本地会员与免广告权益解锁插件。

## 文件说明

| 文件 | 用途 |
|---|---|
| `TMMemberPatch.m` | 插件源码（全部逻辑） |
| `Makefile` | theos 构建配置 |
| `TMMemberPatch.plist` | 注入过滤器，只对 TMLightning 生效 |
| `build.sh` | 本地构建脚本（theos / clang 两种模式） |
| `push.sh` | 推送到 GitHub 触发云端构建 |
| `.github/workflows/build.yml` | GitHub Actions 工作流 |
| `.gitignore` | 排除构建产物与逆向中间文件 |
| `README.md` | 本文件 |

## 云端构建（GitHub Actions）

不用 Mac、不装 Xcode，代码推上去自动出 dylib。

### 首次配置

```bash
# 装 GitHub CLI（Windows: winget install GitHub.cli / Mac: brew install gh）
gh auth login

cd 本目录
./push.sh
# 脚本会初始化 git 仓库并提示下一步

gh repo create TMMemberPatch --private --source=. --push
```

### 日常构建

```bash
./push.sh "改了到期时间"
```

推送后自动触发，流程：

```
检出 → 装 theos → 准备 iPhoneOS SDK → clang 编 arm64 + arm64e
→ lipo 合并 → ldid 签名 → 校验 → 上传 Artifact
```

### 取产物

浏览器打开：

```
https://github.com/你的用户名/TMMemberPatch/actions
```

点最新一次 run → 页面底部 **Artifacts** → 下载 `TMMemberPatch-<sha>-both.zip`。

解压得到：

```
TMMemberPatch.dylib        ← 合并后的 fat，直接注入用这个
TMMemberPatch_arm64.dylib  ← 单 arm64
TMMemberPatch_arm64e.dylib ← 单 arm64e
TMMemberPatch.plist
README.md
```

### 发版本（自动建 Release）

```bash
./push.sh --release v1.0.0
```

打了 `v*` tag 会额外触发 Release 发布，dylib 直接挂在 Releases 页可下载，不用进 Actions。

### 手动触发指定架构

Actions 页面 → 左侧 `Build Dylib` → 右侧 **Run workflow** → 选 `arm64` / `arm64e` / `both`。

### 构建失败排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `theos` 步骤超时 | GitHub 拉 theos 仓库慢 | 重跑一次，或改用仓库缓存 |
| `iPhoneOS SDK` 软链失败 | Xcode SDK 路径变化 | 工作流已用 `xcrun --show-sdk-path` 动态取，一般不受影响 |
| `ldid` 安装失败 | Homebrew 源不稳 | 工作流内置了源码编译兜底 |
| `theos 交叉验证` 报错 | 这是可选项，`continue-on-error` 已设 | 不影响产物，看 `编译 (clang 直出)` 那一步成功即可 |
| Artifact 里没有 dylib | 编译真失败了 | 展开 clang 那一步看报错行号 |

## 逆向依据

- iOS 主二进制 `TMLightning` 33,328,976 字节，arm64 thin，未加密
- ObjC 类 2581 个，Swift 类型 1078 个
- 会员态字段：`isVip` / `is_vip` / `ad_free_time` / `free_time` / `userInfo.expired`
- 核心类：`TMUserInfoCenter`、`TMLightningCenter`、`TMAdFreePayView`、`TMAdManager`

## 构建

```bash
# 方式一：theos
export THEOS=~/theos
./build.sh

# 方式二：只要裸 dylib
./build.sh clang
```

产物：`TMMemberPatch.dylib`（arm64 + arm64e fat）。

## 注入

### 越狱设备

```bash
scp TMMemberPatch.dylib root@设备IP:/Library/MobileSubstrate/DynamicLibraries/
scp TMMemberPatch.plist  root@设备IP:/Library/MobileSubstrate/DynamicLibraries/
ssh root@设备IP "killall -9 TMLightning"
```

### 重打包 IPA

```bash
unzip -o TM手游加速器-2.1.8.ipa -d work
cp TMMemberPatch.dylib work/Payload/TMLightning.app/
optool install -c load -p "@executable_path/TMMemberPatch.dylib" \
    -t work/Payload/TMLightning.app/TMLightning
codesign -f -s "你的证书" work/Payload/TMLightning.app/TMMemberPatch.dylib
codesign -f -s "你的证书" work/Payload/TMLightning.app
cd work && zip -qry ../TMLightning_patched.ipa Payload
```

### 巨魔 / TrollFools

把 dylib 直接拖进 TrollFools 的注入列表，选中 TMLightning 即可。

## 验证

```bash
idevicesyslog | grep TMPatch
```

预期输出：

```
[TMPatch] ==== 注入开始 (TMLightning 2.1.8) ====
[TMPatch] NSUserDefaults[isVip] 改写
[TMPatch] TMUserInfoCenter 会员 getter 已铺(13 项)
[TMPatch] TMAdManager +shared -> nil
[TMPatch] ==== 注入完成, 免广告权益 -> 2045-11-01 ====
```

界面检查：我的 → 免广告权益 → 顶部显示「有效期至：2045-11-01」，三项权益全勾选。

## 权益有效期

源码常量 `kExpireSec = 2398320000.0`（2045-11-01 UTC），改这一行可调整到期日：

```objc
static const double kExpireSec = 2398320000.0;   // 改这里
static NSString * const kExpireText = @"2045-11-01";
```

两个值要一起改成对应的日期。

## 换版本后重定位

App 升级后类名可能变化，按下面步骤重新提取：

1. 解包新 IPA：`unzip -o xxx.ipa -d work`
2. 跑 `__swift5_types` 解析器拿到新类清单
3. 对照 `TMMemberPatch.m` 里 `TMInstallUserHooks` / `TMInstallAds` 的类名数组替换

解析脚本在逆向工作目录 `tm_re/` 下（`a9_parse.py`、`b1_swifttypes.py`）。

## 风险点位

| 位置 | 说明 |
|---|---|
| `TMKillAdMethods` 杀 `start` 前缀 | 若加速功能失效，从前缀表里去掉 `@"start"` |
| `TMURLProtocol` 拦 `/api/` | 若与 App 协议栈冲突，注释掉 `registerClass` 那一行，仅用本地 getter |
| 服务端对账 | 本方案只改本地态，不伪造订单，服务端数据不动 |
