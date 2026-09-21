# Mini Story

一个面向个人使用的 SillyTavern（酒馆）部署包：把角色卡、世界书、聊天记录、内置总结记忆、图片/TTS 接口和登录保护放在一台服务器上，用 Caddy 负责反向代理与 HTTPS。

## 这版包含什么

- SillyTavern 官方稳定 Docker 镜像
- 角色卡、Persona、World Info/Lorebook、群聊和聊天记录
- 酒馆自带的 Memory/总结扩展，用于长对话压缩与记忆注入
- OpenAI、OpenRouter、Claude、Gemini、DeepSeek、vLLM 等接口的统一配置入口（在酒馆界面中配置）
- Caddy 反向代理、HTTP 压缩和基础安全响应头
- SillyTavern 账户登录、离散登录页、CSRF 防护和登录失败限速
- 独立的数据目录与备份/恢复脚本
- 插件和第三方扩展挂载目录

这不是公开的角色社区、支付平台或多租户 SaaS。它的定位是“自己用的小本项目”：先把酒馆体验、角色生态和记忆质量跑通，再按需要增加自定义前端、积分、社区、支付或 Mem0 接入。

## 快速部署

服务器建议 Ubuntu 22.04/24.04、4 vCPU、8 GB RAM、40 GB 以上 SSD。模型推理不在这套容器中完成，服务器只负责酒馆和反向代理。

```bash
cp .env.example .env
nano .env
# 有域名时设置 APP_DOMAIN=chat.example.com，并把 DNS A/AAAA 指向服务器

chmod +x scripts/*.sh
./scripts/install.sh
```

没有域名、只想先用 IP 测试时，把 `.env` 中的 `APP_DOMAIN` 改成 `:80`，并通过 `http://服务器IP` 访问。公开使用时应配置域名和 HTTPS，不要把 8000 端口直接暴露到公网。

第一次打开后创建唯一的 SillyTavern 账户。账户、角色、聊天和设置都保存在 `data/`，不要提交到 GitHub。

## 连接模型

在酒馆的 API Connections 中选择对应的 Chat Completion 后端。自建 vLLM、llama.cpp、One API 或其他 OpenAI-compatible 服务通常使用 Custom/OpenAI-compatible 接口；密钥只保存在服务器上的酒馆数据中，不写进这个仓库。

## 长期记忆

这一版默认使用酒馆内置的 Memory/总结扩展：它会按轮数把旧对话压缩成摘要，并把摘要重新注入提示词。安装后在 Extensions → Memory 中调整摘要间隔、摘要长度和插入位置。

Mem0、Graphiti 这类外部记忆服务不在第一版默认启动，因为它们需要额外的模型、Embedding、数据库和酒馆扩展联动；直接启动一个没有接入酒馆消息流的 Mem0 容器并不会自动产生长期记忆。需要时可以在此仓库上增加专用 ST 扩展和记忆 API。

## 图片、语音和角色卡

酒馆可以在界面中接入图片生成、TTS、翻译和第三方扩展。扩展代码放在 `extensions/`，服务端插件放在 `plugins/`。只安装你信任的第三方扩展；它们会获得酒馆页面或服务端的相应权限。

## 更新与备份

```bash
./scripts/backup.sh
./scripts/update.sh
./scripts/check.sh
```

备份脚本默认不打包 `.env`，避免把域名配置或密钥混进备份。恢复是覆盖操作，必须显式确认：

```bash
CONFIRM_RESTORE=YES ./scripts/restore.sh backups/story-tavern-YYYYmmdd-HHMMSS.tar.gz
```

## 安全边界

- 不要把 `.env`、`data/`、角色卡、聊天记录或 API Key 提交到 GitHub。
- 不要直接把 SillyTavern 的 8000 端口映射到公网；Compose 已默认绑定到服务器本机回环地址。
- Caddy 对外只开放 80/443；服务器防火墙也应只允许必要端口。
- 部署完成后禁止 root 密码 SSH，改用密钥并限制 SSH 来源 IP。
- 不要把未成年人相关内容、违法内容或真实个人敏感资料导入公开分享的角色/知识库。

## 参考

- SillyTavern Docker 安装文档：<https://docs.sillytavern.app/installation/docker/>
- SillyTavern 管理与远程访问说明：<https://docs.sillytavern.app/administration/>

