# 受信学校脚本

这里是 ADR-034 起的客户端受信源码，各包分别声明 SDK 版本，不是 V1 official adapter 目录。脚本由用户检查、导入并批准执行；不会因放入仓库而自动获得安装授权，也不进入公网服务端运行时。

- [西电基本包](xidian/README.md)：本科/研究生教务、通知、校园卡、新 OPAC 借阅及瑞思账号，以及独立官方页面登录包。
- [西电学习通增强包](xidian-chaoxing/README.md)：另行安装的 SDK 9 包，提供服务登录、前台群消息窗口和受限扫码签到。
- [通用 SDK 与格式](../docs/reference/trusted_scripts.md)：背景运行、凭据地址、HTTP/DOM 与版本规则。

各子目录声明自己的许可证。西电适配参考 Traintime PDA 的 MPL-2.0 文件，源码与编译后的 JS 保留该许可；根目录的 MIT 不覆盖这些明确声明为 MPL 的文件。工具使用现有 esbuild（MIT）进行构建，不增加运行时依赖。生成包默认位于各校 `dist/`，不入库，不混入已有签名 bootstrap。
