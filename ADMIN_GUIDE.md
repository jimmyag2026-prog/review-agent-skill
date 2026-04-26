# 🧭 Admin 使用与完善指南

review-agent 装好之后，admin（你）该怎么用、怎么打磨、怎么长期运维。

---

## ⏱ 装完后的 5 分钟

### 1. 验证路由对了（30 秒）

打开两个终端：

```bash
# 终端 A — gateway log
tail -F /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log | \
  grep --line-buffered -E "received message|dispatching"

# 终端 B — watcher seed log
tail -F ~/.openclaw/seeder.log
```

在 Lark 给 bot 发"你是谁"。看终端 A：
- ✅ `dispatching to agent (session=agent:main:main)` — admin 走 main agent，**对**
- ❌ `dispatching to agent (session=agent:feishu-ou_*:main)` — admin 误走 peer，**错** → 跑 `bash vps-doctor.sh`

终端 B 应该**没**新事件（admin 不该 spawn peer）。

### 2. 跑引导式 wizard 填 responder profile（3 分钟）

**这步是最关键的**——不填，review 出来全是泛泛建议。

```bash
bash ~/code/review-agent-skill/assets/admin/setup-responder.sh --guided
```

5 个问题：
1. **Role** — 你的角色（例：startup founder / head of product）
2. **Decision style** — 你怎么决策（例：先要数字、不要 narrative）
3. **Pet peeves** — 什么会让你愤怒（例：vague asks, no ROI）
4. **3 个永远必问的问题** — 每次 review 都会塞进 LLM prompt
5. **额外风格说明**（可选）

写完自动清 session cache，下次 Requester DM 就用新 profile。

### 3. 测试触发（1 分钟）

让另一个 Lark 用户（**不是你**）DM bot 一段方案：

> 帮我看看：我们打算 Q3 推一个新功能 X，需要 3 人 6 个月，预算 200 万

期望：
- 终端 B：`seeded /Users/.../workspace-feishu-ou_<那人>`
- Lark 收到：第一条 finding，开头会带"我扫到 N 条问题，先带你过最关键的 5 条..."

如果 review 出来确实指出方案漏洞、引用了你 wizard 里说的 pet peeves／必问问题——说明 profile 生效了。

---

## 🔁 第一次实战 review 之后（最重要的反馈环）

review-agent 不会 magic 一遍就完美匹配你的风格。你要看它出错的地方，回填 profile。

### 看 review 实际跑出来了什么

每个 Requester 的 session 文件结构：

```
~/.openclaw/workspace-feishu-<oid>/sessions/<session-id>/
  meta.json              # session 元数据
  input/proposal.pdf     # 用户发的原材料
  normalized.md          # ingest.py 跑出的归一化内容
  annotations.jsonl      # 全部 N 条 findings（含没进 top-5 的）
  cursor.json            # 当前 Q&A 进度（top-5 中走到第几条）
  dissent.md             # Requester 反驳过的 finding（"这个不对"）
  final/revised.md       # merge-draft.py 合出的最终 brief
  final/revised_changelog.md  # 改动清单
```

你最该看的：

| 文件 | 干什么 |
|---|---|
| `final/revised.md` | review-agent 的最终成品。你**自己**会改这份吗？哪些改、为啥？ |
| `dissent.md` | Requester 顶嘴说"你抓错重点"的地方。你站谁？ |
| `annotations.jsonl` | 看完所有 finding（不止 top-5）。Top-5 选对了吗？哪几条该升 / 该降？ |

### 三种典型问题 → 怎么调 profile

**问题 1：review-agent 关注了你不在意的点**

例：material 里提到"产品 vs 增长团队的协作"，agent 死抓"组织架构问题"。但你其实不 care。

→ 在 profile 加：
```
## Out of scope (skip these)
- 组织架构 / RACI / 谁汇报给谁。这些应该提案前已经定好。
```

**问题 2：review-agent 漏掉你一定会问的**

例：每次方案你都问 "失败成本是多少？" agent 几乎不抓这个。

→ 在 profile 的 "3 个永远必问的问题" 里加 / 强化：
```
3. 失败的代价是多少（钱 + 信誉 + 错失的别的机会）？没写就 BLOCKER。
```

**问题 3：review-agent 措辞太软**

例：你看 finding 是"建议补充 X 数据"，但你本人会说"没这数你来谈个屁"。

→ 在 profile 加：
```
## Tone
直接、不客套。用"没数你怎么决策"代替"建议补充数据"。可以接近粗鲁。
```

### 改完怎么生效

```bash
bash ~/code/review-agent-skill/assets/admin/setup-responder.sh --edit
# vim 里改完保存
# 脚本会自动清 peer session cache
```

下条新消息会重读 profile。**老的 active session 不会立刻切**——需要清那个 session：
```bash
rm ~/.openclaw/agents/feishu-<oid>/sessions/<session-id>.jsonl
```

---

## 📅 长期运维

### 多个 Requester 怎么管

| 操作 | 命令 |
|---|---|
| 看 dashboard（哪个 Requester 在哪步）| `python3 ~/code/review-agent-skill/assets/admin/dashboard-server.py` 然后开 http://127.0.0.1:8765 |
| 限制只让某些人 DM | 编辑 `~/.openclaw/credentials/feishu-default-allowFrom.json`（加 open_id 白名单）|
| 移除某个 Requester | `bash ~/code/review-agent-skill/assets/admin/remove-peer.sh ou_xxx` |
| 看某个人的 review 历史 | `ls ~/.openclaw/workspace-feishu-<oid>/sessions/` |

### 升级 / 自愈 / 卸载

```bash
# 看版本 + 检查更新
cat ~/.openclaw/skills/review-agent/VERSION
bash ~/.openclaw/skills/review-agent/update.sh --check

# 升级到最新
bash ~/.openclaw/skills/review-agent/update.sh

# 一键自愈（任何状态怪异都能跑）
bash ~/code/review-agent-skill/vps-doctor.sh

# 卸载（保留 session 历史）
bash ~/.openclaw/skills/review-agent/uninstall.sh --yes

# 完全卸载（删所有 peer 数据 + 还原 openclaw.json）
bash ~/.openclaw/skills/review-agent/uninstall.sh --yes --purge --revert-config
```

### 哪些情况要重新跑 wizard

- 换 admin（公司易主 / 你交接给别人审 review）
- 业务模型大变（从"to B 增长"切到"to C 留存"——决策风格不同）
- 看了 5+ 条 review 觉得始终对不上自己的"挑刺"模式

### 哪些情况要重新跑 install

- openclaw 升级后 review-agent 行为变怪（schema 改了）
- 误删了 `~/.openclaw/review-agent/` 或 `~/.openclaw/workspace/templates/review-agent/`
- 想换 admin open_id

```bash
cd ~/code/review-agent-skill && git pull
bash install.sh --enable-only --admin-open-id ou_xxx --responder-name "..."
```

---

## ⚠️ 已知陷阱

| 症状 | 原因 | 修法 |
|---|---|---|
| review 里说 "上级 / your manager" 不说你名字 | profile 里 Name 字段还是 "Responder" | `setup-responder.sh --guided` 重填 |
| 改完 profile 没生效 | session 缓存了老 system prompt | 脚本自动清；或手动 `rm sessions/*.jsonl` |
| 第一条 finding 等了 30s+ | 第一次 ingest（PDF 解析、模型调用）正常 5-30s | 等 |
| Lark 收到 "Something went wrong" | 通常是 sandbox.binds 冲突 | `bash vps-doctor.sh` |
| review 风格泛泛 | profile 没填 | `setup-responder.sh --guided` |
| 模型成本意外高 | review-agent skill 脚本独打 LLM API（每个 finding 一次）| 改 `agents.defaults.model.primary` 到便宜模型，如 deepseek-v4-flash |

---

## 🎯 终极心法

**review-agent 的产出质量 = responder-profile.md 的精准度**

不要把 profile 当 onboarding 表填了就走。把它当**活文档**：每读完一份 review-agent 出的 brief，问自己"这跟我自己写的差在哪"，把差距编码到 profile 里。

3-5 条 review 之后，profile 应该越来越像你的内在标准的外化。

之后新来的 Requester 都自动享受这套标准，不用你每次重新教。
