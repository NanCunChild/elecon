# 构建解环执行草案（build unblock plan）

> 状态：**草案（draft）**，非 ADR。由 AI 起草供维护者评审。触 ADR-008/014 承重依赖，**须人工主导执行**。
> 关联：`docs/notes/build_blockers.md`（现状）、`AGENTS.md` 红线 #4/#5、ADR-008 §3、ADR-014。
> 环境约束：本草案在**无网络**（libsecret 挂起）环境无法执行验证，仅提供可评审的步骤与 diff。

## 0. 为什么不能直接改代码

`flutter_qjs` 现以 **git 依赖** 经 `dependency_overrides` 注入（`client/pubspec.yaml:28-32`）。
若此刻把它改成 `path:` 依赖但**尚未把 fork 源码 vendoring 进仓**，`flutter pub get` 会立即失败。
因此本草案**不预先改 pubspec**——改动必须与 vendoring 动作在同一步完成，且要能联网/离线缓存验证。

阻塞环（摘 `build_blockers.md`）：

```
flutter_qjs 停更 fork
 ├─ 自 apply "kotlin-android" → KGP 弃用警告 → AGP 钉 8.11.1
 ├─ 锁 ffi ^1.x → cryptography 钉 2.6.x（AES-256-GCM 受限）
 ├─ 需 Java 11 pin（脆弱补丁）
 └─ git 依赖 → pub get 经 libsecret 挂起 → path_provider 加不进 → S 档不能落盘
```

两个**相互独立**的切入点（`build_blockers.md:63-64`）：
- **切入点 A（vendoring）**：解 pub git fetch 挂起 → 可加 path_provider。纯流水线改动，风险低，建议先做。
- **切入点 B（fork 迁 built-in Kotlin + 升 ffi）**：解 KGP 警告 + cryptography 钉版本 → 可评估 AGP 9.x。需改 fork 代码，风险中。

---

## 1. 切入点 A：flutter_qjs 去 git 依赖（vendoring / path）

### A.1 步骤（人工，需联网或已有 pub 缓存一次）

1. 在能访问 GitHub 的环境把 fork 固定 ref 的源码取出：
   ```bash
   git clone https://github.com/NanCunChild/flutter_qjs.git /tmp/flutter_qjs
   cd /tmp/flutter_qjs && git checkout dbf5c17233c3c8abfbfa707c297121bb86e54e83
   ```
2. 把源码放入仓库（含 vendored QuickJS 源；pub 不为 git 依赖初始化 submodule，见 pubspec 注释）：
   ```
   client/third_party/flutter_qjs/            # ← vendoring 落点（建议）
   ```
   > 注意 QuickJS C 源与许可证：随源码带上 `LICENSE`；按红线 #9 在 PR 声明许可证。
3. 改 `client/pubspec.yaml` 的 `dependency_overrides`（见 A.2 diff）。
4. `flutter pub get`（此时不再 git fetch → 不受 libsecret 挂起影响）。
5. `flutter pub add path_provider`（阻塞点消失后即可，点亮 §2.8 S 档落盘）。

### A.2 pubspec.yaml diff（草案，**待 vendoring 后再应用**）

```diff
 dependency_overrides:
   flutter_qjs:
-    git:
-      url: https://github.com/NanCunChild/flutter_qjs.git
-      ref: dbf5c17233c3c8abfbfa707c297121bb86e54e83
+    # vendoring 进仓（去 git 依赖，解 pub git fetch 经 libsecret 挂起）。
+    # 更新流程见 docs/notes/build_blockers.md §4 与本草案 A.1。
+    path: third_party/flutter_qjs
```

随后（阻塞解除）：

```diff
 dependencies:
   ...
   cryptography: ">=2.6.0 <2.7.0"
+  # §2.8 S 软件档落盘：app 私有目录（getApplicationSupportDirectory）。
+  path_provider: ^2.1.0
```

### A.3 main.dart 点亮持久化（草案，须与 §2.8 备份排除同批，🔒 人工 + 安全清单审）

```diff
-Future<BlobStore?> _blobStoreProvider() async => null;
+Future<BlobStore?> _blobStoreProvider() async {
+  final dir = await getApplicationSupportDirectory();
+  return FileBlobStore(Directory('${dir.path}/credentials'));
+}
```

> 🔒 **命门（ADR-012 §2.8 / 风险条 10）**：点亮落盘**必须同时**配 Android `allowBackup=false` +
> auto-backup 排除、iOS `isExcludedFromBackup`，否则软件档明文 DEK 随云备份外泄。此项属红线 #1，
> 须人工闭环 + 安全清单必检。

---

## 2. 切入点 B：fork 迁 built-in Kotlin + 升 ffi（fork 侧改动，人工）

在 `flutter_qjs` fork 仓库（非本仓）执行：

1. **去掉自 apply KGP**：删除 fork `android/build.gradle` 里的 `apply plugin: "kotlin-android"`，
   改用 Flutter 3.44+ 的 built-in Kotlin 集成。
2. **升 ffi**：`ffi: ^1.x` → `^2.1`（解 cryptography 2.7+ 冲突）。
3. 回归 fork 自身的 Dart 3 兼容补丁（`lib/src/ffi.dart` 返回类型，见 pubspec 注释）。

fork 迁移完成并 vendoring 后，本仓可推进：

### B.1 gradle 收敛（草案，**待 fork 迁移完成后**）

```diff
# client/android/gradle.properties
-android.builtInKotlin=false
+# fork 已迁 built-in Kotlin，可交回 Flutter 内置 Kotlin 集成（解 KGP 弃用警告）。
+android.builtInKotlin=true
```

```diff
# client/android/build.gradle.kts —— flutter_qjs 的 Java 11 强钉补丁可望移除
-subprojects {
-    if (name == "flutter_qjs") {
-        afterEvaluate { ... Java 11 pin + CMake 3.22.1 + -Wno-int-conversion ... }
-        tasks.withType<KotlinCompile> { jvmTarget JVM_11 }
-    }
-}
+# fork 迁移后逐项验证可移除；移除后即可评估 AGP 9.x（build_blockers.md §1）。
```

```diff
# client/android/settings.gradle.kts —— fork 兼容后评估
-    id("com.android.application") version "8.11.1" apply false
+    id("com.android.application") version "<评估 9.x>" apply false
```

> ⚠ AGP 9.x 升级须在 fork 兼容验证通过后单独一步做，并跑真机构建；不与 vendoring 混在一个 PR。

### B.2 cryptography 升版（草案，待 ffi 解锁）

```diff
# client/pubspec.yaml
-  cryptography: ">=2.6.0 <2.7.0"
+  cryptography: ^2.7.0   # ffi ^2.1 解锁后（红线 #9：许可证/维护状态复核）
```

---

## 3. 建议 PR 拆分（每个都可独立评审 / 回滚）

1. **PR-A1**：vendoring flutter_qjs + pubspec 改 path（切入点 A.1/A.2）。纯流水线，先合。
2. **PR-A2**：加 path_provider + main.dart 点亮 FileBlobStore + **备份排除**（🔒 人工 + 安全清单）。
3. **PR-B1**（fork 仓）：迁 built-in Kotlin + 升 ffi。
4. **PR-B2**：本仓 gradle 收敛（builtInKotlin=true、移 Java 11 补丁）。
5. **PR-B3**：cryptography 升版。
6. **PR-B4**：评估并升 AGP 9.x（真机构建验证）。

## 4. 待办勾稽（与 build_blockers.md §待办对应）

- [ ] PR-A1 vendoring（解 pub git fetch 挂起）
- [ ] PR-A2 path_provider + 落盘 + 备份排除（点亮 §2.8 S 档）🔒
- [ ] PR-B1 fork built-in Kotlin + ffi（解 KGP 警告 + cryptography 钉）
- [ ] PR-B2 gradle 收敛
- [ ] PR-B3 cryptography 升版
- [ ] PR-B4 AGP 9.x 评估
