# 发版流程

适用于 npm 包 `expo-inapp-debugger`。

这份文档面向仓库维护者，目标是把“版本号怎么改、发布前要检查什么、怎么确认发布成功”固定下来，避免每次临时回忆。

## 先知道这几个事实

1. 根目录 `package.json` 是唯一版本源头。
2. `ios/InAppDebugger.podspec` 会读取根目录 `package.json` 的 `version`。
3. `android/build.gradle` 也会读取根目录 `package.json` 的 `version` 作为 `versionName`。
4. 所以正常发版时，只需要改一次根目录 `package.json` 的版本号。
5. `npm publish` 打包的是当前工作区内容，不要求文件必须先 commit；如果工作区是脏的，本地未提交改动也可能被一起发出去。

## 标准发版流程

下面以补丁版本 `+0.0.1` 为例，也就是例如 `0.3.1 -> 0.3.2`。

### 1. 先检查工作区

```bash
git status --short
```

建议：

- 尽量在干净工作区发版。
- 如果必须在脏工作区发版，先确认未提交改动是不是你真的想带进 npm 包。

当前仓库会通过 `package.json` 的 `files` 字段和 `.npmignore` 一起控制最终打包内容。像 `example/`、`__tests__/`、`HANDOFF.md`、`*.tgz` 默认不会进 npm 包，但 `src/`、`ios/*.swift`、`ios/*.podspec`、`android/src`、`android/build.gradle`、`README.md` 会被打进去。

### 2. 确认 npm 登录状态

```bash
npm whoami
```

如果这里失败，先重新登录：

```bash
npm login
```

### 3. 看一下线上当前版本

```bash
npm view expo-inapp-debugger version versions --json
```

目的是确认：

- 当前 `latest` 是多少。
- 你准备发布的新版本号还没被占用。

### 4. 递增版本号

推荐直接用 npm 改补丁版本，但不要自动打 git tag：

```bash
npm version patch --no-git-tag-version
```

如果你只想手动改，也可以直接编辑根目录 `package.json`。

常见版本递增方式：

- `patch`：`+0.0.1`
- `minor`：`+0.1.0`
- `major`：`+1.0.0`

### 5. 发布前校验

最少建议执行：

```bash
npm run typecheck
npm test
npm pack --dry-run
```

重点看三件事：

1. TypeScript 是否通过。
2. 单测是否通过。
3. `npm pack --dry-run` 输出的包名、版本号、以及打包文件列表是否正确。

### 原生代码有改动时，建议再做一层验证

如果这次改到了 `ios/` 或 `android/`，建议至少补一个 example 原生侧编译检查。

Android 可以直接跑：

```bash
cd example/android
./gradlew :app:compileDebugKotlin
```

iOS 视本机环境补充验证，至少保证修改没有破坏已有 Pod / Expo prebuild 流程。

## 6. 正式发布到 npm

```bash
npm publish --access public
```

这个包当前是公开包，发布时应使用 `--access public`。

## 7. 发布后确认

发布完成后立刻检查：

```bash
npm view expo-inapp-debugger version dist-tags --json
```

理想结果是：

- `version` 等于你刚发的版本。
- `dist-tags.latest` 也指向这个版本。

如果只想确认某个精确版本是否已经存在：

```bash
npm view expo-inapp-debugger@0.3.2 version
```

把 `0.3.2` 换成你这次实际发布的版本号即可。

## 8. Git 收尾

如果发布已经成功，再做 git 留档：

```bash
git add package.json
git commit -m "release: v0.3.2"
git tag v0.3.2
git push origin <当前分支>
git push origin v0.3.2
```

如果这次还顺手更新了文档，比如 `README.md` 或本文件，也记得一起 add / commit。

## 一次完整示例

假设当前线上版本是 `0.3.1`，这次要发 `0.3.2`：

```bash
git status --short
npm whoami
npm view expo-inapp-debugger version versions --json
npm version patch --no-git-tag-version
npm run typecheck
npm test
npm pack --dry-run
npm publish --access public
npm view expo-inapp-debugger version dist-tags --json
git add package.json
git commit -m "release: v0.3.2"
git tag v0.3.2
git push origin <当前分支>
git push origin v0.3.2
```

## 常见注意事项

### 1. 为什么 podspec 不需要手动改版本

因为 `ios/InAppDebugger.podspec` 里直接读取的是根目录 `package.json`：

```ruby
package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))
s.version = package['version']
```

### 2. 为什么 Android 也会跟着变

因为 `android/build.gradle` 会从 `package.json` 读取版本号作为 `versionName`。

### 3. 为什么强烈建议在干净工作区发版

因为 npm 发布时使用的是当前磁盘内容，而不是“最后一次 commit 的内容”。如果本地有还没整理好的改动，可能会被一起打进发布包。

### 4. 如果只想试打包、不想真的发布

用：

```bash
npm pack --dry-run
```

如果想生成本地 tarball 做进一步检查，可以用：

```bash
npm pack
```

生成的 `*.tgz` 默认被 `.npmignore` 排除了，不会在下次发布时再被打包进去。

## 最小发版检查清单

每次发版前，至少确认下面这些都成立：

- 目标版本号未被 npm 占用。
- `package.json` 版本号已经更新。
- `npm whoami` 正常。
- `npm run typecheck` 通过。
- `npm test` 通过。
- `npm pack --dry-run` 的文件列表和版本号正确。
- `npm publish --access public` 成功。
- `npm view expo-inapp-debugger version dist-tags --json` 确认 `latest` 已更新。
