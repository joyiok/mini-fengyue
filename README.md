# Mini Story

一个面向个人使用的 SillyTavern（酒馆）部署包：把角色卡、世界书、聊天记录、内置总结记忆、图片/TTS 接口和登录保护放在一台服务器上，用 Caddy 负责反向代理与 HTTPS。

## 这版包含什么

- SillyTavern 官方稳定 Docker 镜像（`ghcr.io/sillytavern/sillytavern`）
- 角色卡、Persona、World Info/Lorebook、群聊和聊天记录
- 酒馆自带的 Memory/总结扩展，用于长对话压缩与记忆注入
- OpenAI、OpenRouter、Claude、Gemini、DeepSeek、vLLM 等接口的统一配置入口（在酒馆界面中配置）
- Caddy 反向代理、HTTP 压缩、基础安全响应头和只读文件系统
- SillyTavern 账户登录、离散登录页、CSRF 防护和登录失败限速
- 独立的数据目录，以及带校验和的备份/恢复脚本和 systemd 定时备份单元
- 插件和第三方扩展挂载目录（服务端插件默认关闭，见下文）

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

`install.sh` 会依次：创建数据目录 → 从 `config/config.yaml.example` 生成 `config/config.yaml` → 运行 `preflight.sh` → 拉取镜像 → **首次单独启动酒馆并把初始管理员密码设好** → 启动全栈 → **等待健康检查通过**，最后打印访问地址和初始账户。

没有域名、只想先用 IP 测试时，把 `.env` 中的 `APP_DOMAIN` 改成 `:80`，并通过 `http://服务器IP` 访问。公开使用时应配置域名和 HTTPS，不要把 8000 端口直接暴露到公网。

`APP_DOMAIN` 支持多个域名，用逗号或空格分隔，Caddy 会为每个域名单独签发证书：

```bash
APP_DOMAIN=chat.example.com, www.chat.example.com
```

**只写你确实解析到这台服务器的域名**：没写进去的名字不会有证书。反过来，如果某个名字解析过来了却没写，访问它会因为证书不匹配而报 TLS 错误。

第一次打开用安装脚本打印出来的账户登录：

```
初始管理员账户:  default-user
初始密码:        （install.sh 随机生成并打印）
```

登录后请立刻在 User Settings 里改成自己的密码，或另建一个你自己的账户。

关于初始账户，有两个坑必须知道（这也是安装脚本要替你做这一步的原因）：

- data 目录为空时，酒馆**总会**创建一个没有密码的 `default-user` 管理员，然后在下一次启动时因为「存在没有密码的管理员」而**直接退出**，容器进入重启循环——不先设密码，你根本打不开页面。
- 而 `user.password` 为空时，登录接口会**整段跳过密码校验**，也就是说任何能访问到页面的人都能以这个管理员身份登入。所以这一步不能靠 `securityOverride` 之类的方式绕过，必须真的设一个密码。

如果用 1Panel，创建 Docker Compose 应用后把这个仓库目录作为项目目录，复制 `.env.example` 为 `.env` 并填写域名，再运行 `scripts/install.sh`。面板和云防火墙只需要放行 80/443；不要额外放行 8000。

## 目录与配置

| 路径 | 作用 | 是否进 Git |
| --- | --- | --- |
| `config/config.yaml.example` | **部署档模板，配置的唯一真源** | 是 |
| `config/config.yaml` | `install.sh` 生成；酒馆每次启动都会重写它（补齐缺失键） | 否（已忽略） |
| `data/` | 账户、角色卡、聊天记录、API Key、`access.log`、酒馆 App 内备份 | 否（已忽略） |
| `backups/` | `backup.sh` 生成的归档与 `.sha256` | 否（已忽略） |
| `caddy/` | Caddy 证书与状态（含 TLS 私钥） | 否（已忽略） |
| `plugins/`、`extensions/` | 第三方代码挂载目录 | 内容忽略，只保留 `.gitkeep` |

要改配置，编辑 `config/config.yaml.example` 后重新执行 `./scripts/install.sh`，或手动 `cp config/config.yaml.example config/config.yaml`。**不要**直接编辑 `config/config.yaml` 并提交，它是运行产物。

想校验改动，随时运行：

```bash
./scripts/preflight.sh   # 只做检查，不改动任何东西
```

`preflight.sh` 会检查 Docker/Compose、`.env` 是否存在与权限、`APP_DOMAIN` 格式、`ST_LOCAL_PORT` 是否仍绑定回环、`PUID/PGID/BACKUP_KEEP` 是否合法，并在 80/443 已被占用时给出警告，最后跑一次 `docker compose config`。它按 `shell 环境变量 > .env > 默认值` 的顺序取值，与 `docker compose` 的优先级一致。

## 连接模型

在酒馆的 API Connections 中选择对应的 Chat Completion 后端。自建 vLLM、llama.cpp、One API 或其他 OpenAI-compatible 服务通常使用 Custom/OpenAI-compatible 接口；密钥只保存在服务器上的酒馆数据中，不写进这个仓库。

自建后端跑在**宿主机**上时要注意：容器里的 `localhost` 不是宿主机。请让服务监听 `0.0.0.0`，然后在 `docker-compose.yml` 的 `sillytavern` 服务里加一条主机映射，再用 `http://host.docker.internal:端口/v1` 作为接口地址：

```yaml
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

如果后端也是容器，更稳的做法是把两个服务放进同一个 Compose 网络，直接用服务名访问。

## 服务端插件

`plugins/` 已挂载，但 `config/config.yaml.example` 里 `enableServerPlugins: false`：**默认不会加载任何服务端插件**。服务端插件在容器内执行任意代码，风险高于纯前端扩展。确实需要时，把 `enableServerPlugins` 改为 `true`，同时保持 `enableServerPluginsAutoUpdate: false`，只从可信来源手动放置插件，然后重启酒馆。

`extensions/` 目录下的第三方前端扩展不受这个开关影响，安装后即可使用。

## 长期记忆

这一版默认使用酒馆内置的 Memory/总结扩展：它会按轮数把旧对话压缩成摘要，并把摘要重新注入提示词。安装后在 Extensions → Memory 中调整摘要间隔、摘要长度和插入位置。

Mem0、Graphiti 这类外部记忆服务不在第一版默认启动，因为它们需要额外的模型、Embedding、数据库和酒馆扩展联动；直接启动一个没有接入酒馆消息流的 Mem0 容器并不会自动产生长期记忆。需要时可以在此仓库上增加专用 ST 扩展和记忆 API。

## 图片、语音和角色卡

酒馆可以在界面中接入图片生成、TTS、翻译和第三方扩展。扩展代码放在 `extensions/`，服务端插件放在 `plugins/`。只安装你信任的第三方扩展；它们会获得酒馆页面或服务端的相应权限。

## 更新、锁版本与回滚

```bash
git pull --ff-only
./scripts/update.sh
```

`update.sh` 会先跑 `preflight.sh` → 打印当前镜像 → 自动备份 → 拉取新镜像 → 重启 → 运行 `check.sh`。旧镜像默认保留，方便立刻回滚；确认没问题后再用 `PRUNE_IMAGES=YES ./scripts/update.sh` 回收磁盘。

`.env` 里 `SILLYTAVERN_VERSION=latest` 跟随上游 release 分支，是**移动目标**：上游一发新版本，`docker compose pull` 就会升级。想要可复现部署，把它钉到具体版本，例如：

```bash
SILLYTAVERN_VERSION=1.13.4
```

回滚步骤：把 `SILLYTAVERN_VERSION` 改回上一个值（或改回 `latest`），执行 `docker compose pull sillytavern && docker compose up -d`；如果新版本已经迁移过配置，再用 `restore.sh` 恢复升级前的归档。

日常自检：

```bash
./scripts/check.sh
```

它会验证酒馆自身的 healthcheck、Caddy 容器状态，并通过 **Caddy 实际请求一次站点**（域名模式用 `--resolve` 直连本机，因此不依赖公网 DNS，同时能验证证书是否签发成功）。私有环境里不想做这一步时：`SKIP_PROXY_CHECK=YES ./scripts/check.sh`。

## 备份与恢复

```bash
./scripts/backup.sh                 # 生成 backups/story-tavern-<时间戳>.tar.gz 与 .sha256
BACKUP_KEEP=30 ./scripts/backup.sh  # 覆盖 .env 中的保留数量
```

- 归档内容：`config/`、`data/`（含聊天记录、角色卡、API Key、酒馆 App 内备份、`access.log`）、`plugins/`、`extensions/`、`caddy/`。
- 排除内容：`.env`（里面有域名与轮换设置，请单独存进密码管理器）、`config/config.yaml.example`、`Caddyfile` 和 `docker-compose.yml`（这三个是 Git 管理的代码，恢复时不会被归档覆盖，避免静默降级编排配置）。
- 每个归档都有 `.sha256`，可以用标准命令校验：`sha256sum --check backups/story-tavern-*.sha256`。
- 也可以让脚本完整校验一个归档（含格式、路径安全与校验和），不恢复、不接触容器：

  ```bash
  VALIDATE_ONLY=YES ./scripts/restore.sh backups/story-tavern-YYYYmmdd-HHMMSS.tar.gz
  ```

- 归档先写 `.partial` 再改名，tar 失败时不会留下半截文件；`BACKUP_KEEP=0` 表示不轮换、全部保留。
- **归档里含有 Caddy 的 TLS 私钥**，请按机密文件对待（脚本已设为 `600`）。

恢复是覆盖操作，且必须显式确认：

```bash
CONFIRM_RESTORE=YES ./scripts/restore.sh backups/story-tavern-YYYYmmdd-HHMMSS.tar.gz
```

`restore.sh` 的顺序是：完整读取归档 → 拒绝绝对路径/上级目录 → 确认这是本项目的备份 → **校验 `.sha256`** → 跑 `preflight.sh`（缺 `.env` 会在这里就失败，此时还什么都没动）→ 自动做一次安全备份 → 停止容器 → 解压数据（排除上述代码文件）→ 启动 → 跑 `check.sh` → 打印一条“如何撤销本次恢复”的命令。

也就是说：解压之前一定有一份回滚用的归档；恢复失败时脚本会尝试把容器重新拉起。

跨机恢复时先 `git clone` 本仓库、重建 `.env`，再执行恢复。

## 定时备份

仓库自带 systemd 单元（推荐）：

```bash
sudo cp deploy/systemd/story-tavern-backup.{service,timer} /etc/systemd/system/
sudo nano /etc/systemd/system/story-tavern-backup.service   # 改成你的路径和属主
sudo systemctl daemon-reload
sudo systemctl enable --now story-tavern-backup.timer
systemctl list-timers story-tavern-backup.timer
```

用 cron 也可以（注意用拥有仓库目录的用户，而不是 root）：

```cron
0 4 * * * cd /opt/story-tavern && ./scripts/backup.sh >> backups/backup.log 2>&1
```

无论用哪种方式，都建议定期把归档复制到另一台机器或对象存储，并偶尔做一次真实恢复演练——没验证过的备份不算备份。

## 卸载

```bash
./scripts/uninstall.sh                     # 只停容器，保留 data/、backups/、caddy/
CONFIRM_PURGE=YES ./scripts/uninstall.sh   # 连私有数据一起删除
```

## 排障

先跑 `./scripts/check.sh`：它会分别验证酒馆自身的健康检查、Caddy 容器状态，以及经反代的一次真实请求。多数问题能从这里定位。

**拉不到镜像（`failed to do request: Head "https://ghcr.io/..." : EOF`）**

SillyTavern 只发布在 `ghcr.io`，Caddy 来自 Docker Hub，两个源在国内都可能连不上，这是最常见的失败。`install.sh` 会自动重试一次，仍失败时列出两个镜像和对应的开关。把连不上的那个换成镜像源即可（改完重新执行 `install.sh`）：

```bash
# .env
SILLYTAVERN_IMAGE=ghcr.nju.edu.cn/sillytavern/sillytavern   # 代理 ghcr.io
CADDY_IMAGE=docker.m.daocloud.io/library/caddy:2-alpine    # 代理 Docker Hub
```

`SILLYTAVERN_IMAGE` 只写仓库、不要带 tag（tag 由 `SILLYTAVERN_VERSION` 给），`preflight.sh` 会拒绝 `xxx:1.13` 这种写法；`CADDY_IMAGE` 则是完整引用、含 tag。

如果镜像已经手动导入到本地，可以完全跳过拉取：

```bash
SKIP_PULL=YES ./scripts/install.sh
```

**容器起不来或一直是 unhealthy**

```bash
docker compose ps
docker compose logs --tail=100 sillytavern
docker compose logs --tail=50 caddy
```

- Caddy 依赖酒馆健康：酒馆不健康时 Caddy 不会启动，这是设计而非故障。
- `heartbeatInterval` 必须大于 0，否则健康检查永远失败（模板里已是 30）。
- 酒馆在 `listen` 模式下，如果存在**没有密码的管理员账户**会直接退出，容器进入重启循环。用下面的找回命令补上密码。

**忘记账户密码 / 账户被禁用**

酒馆自带找回脚本，在容器里执行：

```bash
docker compose exec sillytavern node recover.js <账户名> <新密码>
# 例如：docker compose exec sillytavern node recover.js default-user 'my-new-password'
```

**一定要带上新密码**：省略密码会把密码设成空字符串，而空密码的账户不仅能让人免密登录，还会让酒馆在下次启动时直接退出。

如果容器正在重启循环、`exec` 插不进去（例如你手动清空了 `data/`），用一次性容器执行，这也是 `install.sh` 的做法：

```bash
docker compose stop sillytavern
docker compose run --rm --no-deps --user "$(id -u):$(id -g)" \
  --entrypoint node sillytavern recover.js default-user 'my-new-password'
docker compose up -d
```

**证书申请失败（域名模式）**

- 检查 DNS 是否已把 `APP_DOMAIN` 里的每个名字都指向本机，且 80/443 已放行（Caddy 的 HTTP-01 校验需要 80）。
- 看日志：`docker compose logs --tail=100 caddy`；确认后重启：`docker compose restart caddy`。
- 注意 `APP_DOMAIN` 里没列出的域名不会有证书，浏览器会报证书不匹配。

**用了 Cloudflare 代理（橙色云朵）**

实测可用：Cloudflare 代理下 Caddy 仍能通过 HTTP-01 拿到 Let's Encrypt 证书，无需改成 DNS 校验。

- Cloudflare 的 SSL/TLS 模式建议设为 **Full (strict)**：边缘到源站也走加密且校验证书。用 `Flexible` 时 Cloudflare 以明文 HTTP 回源，而 Caddy 会把 HTTP 重定向到 HTTPS，容易形成重定向循环。
- 首次加域名后，Cloudflare 的通用证书可能要几分钟才下发。这期间 `https://www.你的域名` 可能报 `unable to get local issuer certificate`；等证书下发后重试即可（源站证书本身是正常的，可用 `curl --resolve 域名:443:127.0.0.1` 在服务器上单独验证）。
- 真实客户端 IP 由 Cloudflare 通过 `X-Forwarded-For` 传到 Caddy，再传给酒馆，所以登录限速按真实 IP 计数，不会把所有人算成一个 IP。
- 如果流式输出出现卡顿或成块出现，先排查 Cloudflare 的 Rocket Loader / 各项优化开关，它们会缓冲响应。

**以 root 部署后，证书目录写不进去**

`install.sh` 会自动把 `config/`、`data/`、`caddy/` 等运行时目录交给 `PUID:PGID`（默认 1000），因为 Caddy 容器以该用户运行。如果看到 `mkdir /data/caddy: permission denied`，说明目录属主不对：

```bash
sudo chown -R 1000:1000 caddy      # 或 .env 里你设置的 PUID:PGID
docker compose restart caddy
```

`preflight.sh` 会提前检查这一点并给出同样的修复命令。

**端口被占用**

`preflight.sh` 会在 80/443 已被占用时警告。`ss -ltnp | grep -E ':(80|443)'` 找到占用者；若是另一个 Web 服务，需要停掉它或改用它做前端。

**`data/` 或 `caddy/` 权限报错**

容器内用 `PUID`/`PGID`（默认 1000）写挂载目录。若宿主机目录属于其他 uid：

```bash
ls -ln data caddy
# .env 里改成实际的属主，然后
docker compose up -d --force-recreate
```

**磁盘被占满**

`data/` 会随聊天记录、角色卡和缩略图增长，`data/access.log` 也会持续写入。用 `du -sh data/* | sort -h` 定位。每日定时备份见上文；归档自己也在 `backups/` 下轮换（`BACKUP_KEEP`）。

**时间不对**

容器时区来自 `.env` 的 `TZ`；改完 `docker compose up -d --force-recreate` 生效。

## 脚本与开关速查

每个脚本都可以单独运行，且都会先做检查：

| 脚本 | 作用 |
| --- | --- |
| `scripts/preflight.sh` | 只检查不改动：Docker/Compose、`.env` 与权限、`APP_DOMAIN` 格式、镜像名、端口占用、`PUID/PGID/BACKUP_KEEP` |
| `scripts/install.sh` | 首次部署：建目录 → 生成 `config/config.yaml` → 检查 → 拉镜像 → 启动 → 等健康检查 |
| `scripts/check.sh` | 自检：酒馆健康 + Caddy 状态 + 经反代的真实请求（含证书） |
| `scripts/update.sh` | 更新：检查 → 打印当前镜像 → 自动备份 → 拉镜像 → 重启 → 自检 |
| `scripts/backup.sh` | 备份到 `backups/story-tavern-<时间戳>.tar.gz`（+ `.sha256`） |
| `scripts/restore.sh` | 恢复（覆盖操作，必须显式确认） |
| `scripts/uninstall.sh` | 停栈；加 `CONFIRM_PURGE=YES` 才删数据 |

可用的环境变量：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `BACKUP_KEEP` | `14` | 保留归档数；`0` 表示不轮换、全部保留。也可写成 `BACKUP_KEEP=30 ./scripts/backup.sh` |
| `CONFIRM_RESTORE` | — | 必须为 `YES` 才执行恢复 |
| `VALIDATE_ONLY` | — | `YES` 只校验归档与 `.sha256`，不恢复、不需要确认、不接触容器 |
| `SKIP_SAFETY_BACKUP` | — | `YES` 跳过恢复前的自动安全备份（脚本会打印撤销命令，恢复安全归档时用它） |
| `SKIP_PROXY_CHECK` | — | `YES` 跳过 `check.sh` 的反代请求检查（私有网络里证书不受信时有用） |
| `SKIP_PULL` | — | `YES` 跳过镜像拉取，直接用本地已有镜像（离线部署或已手动导入镜像时用） |
| `PRUNE_IMAGES` | — | `YES` 在 `update.sh` 成功后清理成为悬空的旧镜像；默认保留以便秒级回滚 |
| `CONFIRM_PURGE` | — | `YES` 让 `uninstall.sh` 连 `data/`、`caddy/`、`backups/` 一起删除 |

`.env` 里的配置项（`APP_DOMAIN`、`CADDY_EMAIL`、`TZ`、`SILLYTAVERN_IMAGE`、`SILLYTAVERN_VERSION`、`CADDY_IMAGE`、`PUID`、`PGID`、`ST_LOCAL_PORT`、`BACKUP_KEEP`）都有注释说明；脚本读取 `.env` 的规则与 `docker compose` 完全一致（行内注释、引号、重复键后者覆盖、`${VAR}` 插值），并且 **shell 环境变量优先于 `.env`**，与 Compose 相同。

## 安全边界

- 不要把 `.env`、`data/`、`backups/`、`caddy/` 提交到 GitHub；这些路径已在 `.gitignore` 中，`config/config.yaml` 也不再被跟踪。
- 不要直接把 SillyTavern 的 8000 端口映射到公网；Compose 已默认绑定到服务器本机回环地址（`preflight.sh` 会拒绝其他写法）。
- Caddy 对外只开放 80/443；服务器防火墙也应只允许必要端口。Caddy 容器以 `PUID`/`PGID`（默认 1000）运行，配合只读根文件系统，因此它写出的证书不会变成 root 属主文件——备份能读到、卸载能删掉（`preflight.sh` 会在目录被 root 占用时给出修复命令）。
- `.env` 建议保持 `chmod 600`（`preflight.sh` 会在权限过松时警告）。
- 默认 `sessionTimeout: -1` 表示登录会话永不过期。公网可达时建议在 `config/config.yaml.example` 里改成秒数（例如 `604800`）。
- 需要更强的边界时，可以在 Caddy 前再加一层 Cloudflare Access、VPN 或 IP 白名单；本仓库没有内置双因素认证。
- 部署完成后禁止 root 密码 SSH，改用密钥并限制 SSH 来源 IP。
- 不要把未成年人相关内容、违法内容或真实个人敏感资料导入公开分享的角色/知识库。

## 可选：资源限制

Compose 没有预设内存/CPU 上限，避免在低配机器上误杀酒馆。需要时用 `docker-compose.override.yml`（Compose 会自动合并，且不需要改本仓库文件）：

```yaml
services:
  sillytavern:
    mem_limit: 4g
    cpus: 2
```

## 已知边界

- 单用户、单实例，没有多租户、计费和社区功能。
- 不带外部记忆服务（Mem0/Graphiti）与双因素认证。
- Caddyfile 只有基础安全响应头，没有 HSTS、请求体大小限制和访问日志；需要时按 [Caddy 文档](https://caddyserver.com/docs/caddyfile/directives) 自行添加。
- 本仓库尚未声明开源许可证。上游 SillyTavern 采用 AGPL-3.0，你若分发本部署包，请自行确认合规并补上 LICENSE。

## 参考

- SillyTavern Docker 安装文档：<https://docs.sillytavern.app/installation/docker/>
- SillyTavern 管理与远程访问说明：<https://docs.sillytavern.app/administration/>
