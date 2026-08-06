# XIDIAN 请求测试

- schoolId: `school-xidian`
- school: 西安电子科技大学
- systems: IDS、E-Hall、教务、一卡通、图书馆、水电
- status: `active`
- sensitivity: `credential-sensitive`
- inUse: 是；用于 fixture、接口逆向和 adapter 回归

请求来源映射、运行依赖和安全要求见 [`ORIGIN.md`](ORIGIN.md)。所有 live 探针只允许在
本地交互运行，输出必须脱敏，且不得进入正式 adapter 发布目录。
