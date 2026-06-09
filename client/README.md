# client/ — Flutter 客户端

## 结构

```
lib/
  main.dart     入口
  core/         可信核心（凭证保管、broker、签名校验）
  ui/           UI 层（数据驱动 / SDUI，只认标准 schema）
assets/         静态资源
```

## 运行

```bash
cd client
flutter pub get
flutter run
```

## 原则

- adapter 在后台 isolate 执行，不在 UI 线程同步阻塞
- UI 只认标准 schema，与学校无关
- 凭证永不离开核心
