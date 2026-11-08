# Docker 部署

这个仓库带一个 Dockerfile，把卡拉 OK 的网页服务、搜索、房间和播放器打包成
一个镜像。

## 这个镜像能做什么

- 打开网页点歌台、正在播放、待唱列表
- 按歌名或歌手搜索 YouTube，查看搜索结果
- 点歌、排队、切歌、调整主唱音量、升降半音
- 播放已经准备好的歌（伴奏、伴唱、主唱分轨，字幕逐字高亮）
- 多设备共用一个房间：一台点歌，手机点歌，电视投屏播放

## 这个镜像不能做什么

**镜像里没有分离模型，也没有 PyTorch，所以不能从 YouTube 现场准备一首歌。**

点歌之后，下载、取视频、取歌词这几步都能跑通，但人声分离那一步会失败，
任务状态是 `failed`，错误是 `ModuleNotFoundError: No module named 'torch'`。

这不是配置错了，是这个镜像的边界。分离要下载模型权重（几个 GB），还要按
硬件装对应的 PyTorch 轮子，所以单独拆成另一个镜像，见下面的「完整处理环境」。

现在这个镜像的用处是：**把它当成播放器和点歌台**。已经准备好的歌放在
数据卷里就能播；准备的工作交给另一套环境。

## 快速开始

```sh
docker compose up -d
```

打开 <http://127.0.0.1:8746/>。接口文档在 <http://127.0.0.1:8746/docs>。

换主机端口就改 `docker-compose.yml` 里的 `ports` 左边那个数字：

```yaml
ports:
  - "9000:8746"
```

## 不用 compose

```sh
docker build -t dicklamman/ha_karaoke:latest .
docker run -d --name karaoke -p 8746:8746 -v karaoke-data:/data \
  dicklamman/ha_karaoke:latest
```

## 数据卷

服务把状态放在 `KARAOKE_DATA_DIR`（默认 `/data`），里面有：

| 内容 | 说明 |
| --- | --- |
| `jobs.sqlite3` | 任务状态、房间、播放记录 |
| `<任务 id>/` | 每首歌的歌词、字幕、分离出的音轨、MV |
| `stage-locks/` | 各阶段的互斥锁，服务重启后继续用它 |
| `worker.lock` | 保证同一个数据目录只跑一个 worker |

这个目录必须挂成卷，否则重建镜像时歌库就没了。compose 里已经配好了
`karaoke-data` 这个命名卷。

要换到宿主机上的目录，把 compose 里的 volume 改成绑定挂载：

```yaml
volumes:
  - /path/on/host/karaoke:/data
```

## 环境变量

在 `docker-compose.yml` 的 `environment` 里改。

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `KARAOKE_HOST` | `0.0.0.0` | 容器里必须填 `0.0.0.0`，否则宿主机连不上 |
| `KARAOKE_PORT` | `8746` | 容器内端口 |
| `KARAOKE_DATA_DIR` | `/data` | 歌库和任务状态的目录 |
| `KARAOKE_CACHE_MAX_GIB` | `10` | 歌库容量上限（GiB）。超过后会自动清理最旧的歌，正在播的和排队的歌不会被清掉 |
| `KARAOKE_PREPARATION_CONCURRENCY` | `1` | 同时准备的歌曲数 |
| `KARAOKE_DEVICE` | `auto` | 这个镜像没有 GPU，填 `cpu` |
| `KARAOKE_ASR_BACKEND` | `api` | 歌词和元数据用 OpenAI API |
| `KARAOKE_CORS_ORIGINS` | 本地 8745 | 允许调用接口的来源，逗号分隔 |
| `KARAOKE_MAX_DURATION_SECONDS` | `900` | 单曲时长上限 |

要用 OpenAI 那几步（歌词整理、元数据补全），加上你的 key：

```yaml
environment:
  OPENAI_API_KEY: "${OPENAI_API_KEY}"
```

没配 key 的时候，搜索、下载、播放都正常，只有需要模型的那几步会失败。

## 镜像里装了什么

| 组件 | 用途 |
| --- | --- |
| Python 3.12 | 服务本体 |
| ffmpeg / ffprobe | 解码、转码、封装 |
| lame | 写 MP3 预览（LAME 前端，不是 ffmpeg） |
| nodejs | yt-dlp 解 YouTube 链接要 JavaScript 运行时 |
| fontconfig + Noto CJK | 字幕渲染按字形挑字体 |
| libsndfile1 | soundfile 读写 WAV |
| espeak-ng | 兜底对齐用的音素模板 |
| tzdata | 没有 zoneinfo 时 TZ 名字会被忽略，时间会停在 UTC，字幕时轴就偏了 |

Python 依赖是 `karaoke/requirements-api.txt` 这一套轻量的，本来不含
`requests`（歌词查询会用到，但上游漏写了），Dockerfile 里补上了。

## 完整处理环境

要在容器里真的从 YouTube 准备出一首歌，需要另外一套带模型的环境：

- PyTorch（按 CPU / CUDA 选轮子）
- 分离模型权重，放到 `karaoke/models/pretrained/`
- `audio-separator` 和 `librosa`，放在单独的 venv 里，用
  `KARAOKE_SEPARATOR_PYTHON` 指过去
- 字幕对齐模型，放到 `karaoke/models/alignment/`

上游的 [SETUP.md](SETUP.md) 写了完整的安装步骤和模型下载清单，包括校验值。
那份文档是按 macOS / Linux 裸机写的，容器里还要处理 CUDA 设备透传
（`--gpus all`）和模型权重的挂载。

这个仓库的 Dockerfile 暂时只覆盖 API/播放这一层。
