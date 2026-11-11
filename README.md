# gh-runner-lab

Lab nhỏ, tự chứa: dựng **2 system container Incus**, mỗi container chạy **một
GitHub Actions self-hosted runner dạng ephemeral** (mỗi job một runner mới).
Toàn bộ điều khiển bằng một script `lab.sh`.

```
host Ubuntu 26.04 + incus 6.0.5
└── incusbr0 (10.156.39.0/24, NAT, dnsmasq)
    ├── gh-runner-1  (4 CPU, 6GiB)  → gh-runner.service → 1 job → restart
    └── gh-runner-2  (4 CPU, 6GiB)  → gh-runner.service → 1 job → restart
```

Đưa repo lên GitHub và chạy runner ngay trên máy này (không cần Incus): xem
[`GITHUB.md`](GITHUB.md) và [`local-runner/README.md`](local-runner/README.md).

## Hai đường provisioning

Lab cố ý giữ **hai** đường độc lập, mỗi đường chạy được một mình:

| | Path A — cloud-init | Path B — Ansible |
|---|---|---|
| File | `cloud-init/runner.yaml` | `ansible/prepare.yml`, `ansible/runner.yml` |
| Chạy khi nào | Chỉ lần boot đầu tiên của container | Bất cứ lúc nào, chạy lại bao nhiêu lần cũng được |
| Tính chất | Khai báo, one-shot, không sửa lại được | Idempotent, tự sửa trạng thái lệch |
| Lệnh | `./lab.sh create` | `./lab.sh ansible prepare`, `./lab.sh ansible runner` |
| Hợp với | Đóng gói baseline cho container mới | Lặp lại, sửa lỗi trên container đang chạy |

**Đường nào dạy điều gì.** Path A dạy cách mô tả một máy bằng dữ liệu: toàn bộ
file là YAML khai báo, không có bước nào, và kết quả chỉ thấy được trên container
vừa tạo. Path B dạy cách giữ một máy ở trạng thái mong muốn: mỗi task tự kiểm tra
trước khi làm, nên chạy lần hai không đổi gì, và lỗi giữa đường thì chạy lại là
xong.

cloud-init **chỉ áp dụng ở lần boot đầu**. `incus profile set ... cloud-init.user-data`
sau đó chỉ ảnh hưởng container được tạo *mới*; container đang chạy không nhận gì
cả. Đó là lý do các thay đổi cần lặp lại nằm trong `ansible/`.

## Phần mềm trong container

| Thành phần | Path A (cloud-init) | Path B (Ansible) |
|---|---|---|
| Gói apt nền | `packages:` trong `cloud-init/runner.yaml` | task "Install base packages" trong `ansible/prepare.yml`, cùng danh sách |
| GitHub CLI | không có | repo apt chính thức + `gh` |
| uv | không có | `/usr/local/bin/uv` cho mọi user |
| ruff | không có | `uv tool install ruff` cho `ubuntu`, symlink `/usr/local/bin/ruff` |
| PostgreSQL | `postgresql`, `libpq-dev` | như trên + role `ubuntu` (idempotent) |
| Redis | `redis-server` | như trên + unix socket (idempotent) |
| Runner binaries | không có | `ansible/runner.yml` |

`gh`, `uv`, `ruff` chỉ có ở Path B (và ở `./lab.sh toolchain`) — cloud-init giữ
đúng danh sách gói tối thiểu, phần còn lại là việc của đường idempotent.

## PostgreSQL và Redis

Cả hai chỉ nghe trên loopback (Redis `127.0.0.1:6379`, PostgreSQL
`127.0.0.1:5432`) và **không** expose ra `eth0`; lab dùng unix socket cho cả hai
nên không có cổng nào phải mở.

**Redis** — socket `/run/redis/redis-server.sock`, quyền `766`, khai báo trong
`/etc/redis/redis.conf` (`unixsocket`, `unixsocketperm`). Ubuntu không có
`conf.d` include nên cả hai đường đều sửa trực tiếp file này.

```bash
incus exec gh-runner-1 -- redis-cli -s /run/redis/redis-server.sock ping
```

**PostgreSQL** — role `ubuntu` (superuser, **không mật khẩu**), xác thực peer
qua unix socket, nên user nào đăng nhập được vào container thì vào được database
bằng chính tên đó.

```bash
incus exec gh-runner-1 -- psql -c 'select current_user, version()'
```

Biến môi trường cho project FastAPI (SQLAlchemy async + asyncpg trỏ vào socket):

```bash
DATABASE_URL=postgresql+asyncpg:///postgres?host=/var/run/postgresql
REDIS_URL=unix:///run/redis/redis-server.sock
```

## Kiểm tra trước khi chạy

```bash
incus list                  # phải liệt kê được container
id -nG | grep incus-admin   # phải thấy incus-admin
```

Nếu `incus list` báo lỗi quyền: phiên đăng nhập chưa có group. Sửa bằng
`su - $USER`, `newgrp incus-admin`, hoặc logout/login hẳn.

## Thứ tự chạy

```bash
sudo ./lab.sh host-prep          # 1 lần duy nhất, cần sudo
./lab.sh create                  # profile + containers + cloud-init
./lab.sh toolchain               # hoặc: ./lab.sh ansible prepare
./lab.sh runner                  # hoặc: ./lab.sh ansible runner
./lab.sh register OWNER/REPO <token>
```

`toolchain`/`runner` là bản imperative (gọi `incus exec`); `ansible prepare`/
`ansible runner` làm cùng việc nhưng qua playbook idempotent. Chọn một, hoặc
chạy cả hai để so sánh — chạy lần lượt cũng không hỏng gì.

Ansible cần cài trên **host**, không phải trong container:

```bash
sudo apt install -y ansible
ansible-galaxy collection install -r ansible/requirements.yml
./lab.sh ansible prepare
./lab.sh ansible runner
```

`./lab.sh ansible` tự sinh `ansible/inventory.generated.yml` từ các container
đang có (file này **không** commit, mỗi lần chạy lại ghi đè). Inventory dùng
`ansible_connection: community.general.incus`; chỉ cần thêm
`ansible_incus_project` khi user hiện tại **không** thuộc group `incus-admin`.

Biến môi trường ghi đè: `RUNNER_COUNT`, `RUNNER_PREFIX`, `PROFILE`, `IMAGE`,
`RUNNER_LABELS`, `RUNNER_VERSION`, `RUNNER_CPU`, `RUNNER_MEM`,
`RUNNER_WORKDIR`, `GH_RUNNER_TOKEN`, `GH_RUNNER_PAT`.

## Các gotcha và cách xử lý

| Hiện tượng | Nguyên nhân | Fix |
|---|---|---|
| Lệnh trong container treo, không trả về | Ubuntu 25.04+ giới hạn AppArmor cho unprivileged unconfined profile | `host-prep` ghi `/etc/sysctl.d/50-incus-apparmor.conf` với `kernel.apparmor_restrict_unprivileged_unconfined=0` (nguồn: quan.hoabinh.vn, bài 2025/11 "fix commands hanging in incus container") |
| systemd trong container không khởi động được unit, hoặc job cần Docker/user namespace | Thiếu nesting | Profile `gh-runner` đặt `security.nesting=true` |
| Container không resolve được DNS | `systemd-resolved` trên host (127.0.0.53) không phục vụ container | `incusbr0` đã có `raw.dnsmasq "server=1.1.1.1"`; lưu ý setting này tắt AppArmor cho tiến trình dnsmasq của Incus |
| `/dev/kvm` có trên host nhưng không dùng | Ta chạy system container, không phải VM | Bỏ qua, không cần cấu hình gì |
| `./lab.sh ansible ...` không kết nối được container | Thiếu group, hoặc collection chưa cài | `id -nG \| grep incus-admin` phải thấy `incus-admin`; kiểm tra `ansible-galaxy collection install -r ansible/requirements.yml` đã chạy xong chưa (`ansible-galaxy collection list \| grep community.general`) |
| Sửa `cloud-init.user-data` rồi mà container không đổi | cloud-init chỉ chạy lần boot đầu | Tạo lại container (`./lab.sh destroy --yes && ./lab.sh create`), hoặc dùng `./lab.sh ansible prepare` |

## Lấy registration token

Cách 1 — giao diện web: repo → **Settings → Actions → Runners → New self-hosted
runner**, copy giá trị sau `--token`.

Cách 2 — CLI:

```bash
gh api -X POST /repos/OWNER/REPO/actions/runners/registration-token -q .token
```

Token hết hạn sau khoảng 1 giờ, nên lấy ngay trước khi `register`.

## Ephemeral: đọc trước khi dùng

`config.sh` được gọi với `--ephemeral`: runner **tự hủy đăng ký sau đúng một
job**, nên mỗi lần chạy lại cần token đăng ký mới. Vì vậy `lab.sh register`
cài thêm `/opt/actions-runner/run-ephemeral.sh` và một unit systemd
`Restart=always`: wrapper lấy token mới từ GitHub API rồi mới `./run.sh`.

Wrapper chỉ lấy được token mới khi có PAT ở `/etc/gh-runner/token`
(xuất `GH_RUNNER_PAT` trước khi chạy `register`). Không có PAT thì chỉ job đầu
tiên chạy được.

Muốn quay về runner **persistent** (đăng ký một lần, chạy mãi):

1. Bỏ `--ephemeral` trong lệnh `config.sh` (cả trong `lab.sh register` và
   trong `run-ephemeral.sh`).
2. Cho unit chạy thẳng `./run.sh` thay vì wrapper, hoặc để wrapper gọi
   `./run.sh` mà không đăng ký lại.

## Troubleshooting

```bash
incus list
incus exec gh-runner-1 -- ping -c1 10.156.39.1     # kiểm tra ra gateway
incus exec gh-runner-1 -- journalctl -u gh-runner -f
./lab.sh status
./lab.sh logs                # 50 dòng cuối của gh-runner trên gh-runner-1
./lab.sh logs gh-runner-2
incus exec gh-runner-1 -- gh-runner-info           # tên + IP container
```

Job không được nhận: kiểm tra `RUNNER_LABELS` có khớp `runs-on` trong workflow
không (mặc định `self-hosted,linux,x64,incus`).

## Dùng lại cho repo khác — `template/`

Lab này là bản tham chiếu một project. `template/` là bản **copy-and-adapt**: copy
nguyên thư mục sang repo của bạn, sửa đúng một file YAML, chạy vài lệnh. Tài liệu
trong đó viết tiếng Anh để đưa được cho người khác.

```
template/
├── requirements/<repo>.yml   # file duy nhất bạn sửa: gói apt, repo apt, uv, node, service, sysctl, env
├── scripts/render.py         # YAML → cloud-init/user-data.yaml + ansible/vars/generated.yml
├── schema/                   # JSON Schema để editor validate
├── ansible/                  # prepare.yml (idempotent) + runner.yml
├── tests/                    # 36 contract test, stdlib unittest
└── setup.sh                  # render / create / prepare / runner / register / status / destroy
```

```bash
cd template
./setup.sh render requirements/python-fastapi.yml
./setup.sh create && ./setup.sh prepare && ./setup.sh runner
```

Khác biệt có chủ đích so với `lab.sh`:

| | `lab.sh` (lab này) | `template/setup.sh` |
|---|---|---|
| Tên, image, user, gói | hardcode trong script | sinh từ `requirements/*.yml` |
| Profile Incus | `gh-runner` | `<name>` + marker `user.kit` (từ chối sửa profile lạ, kể cả `default`) |
| Container lạ cùng tên | không kiểm tra | từ chối, chỉ nhận container gắn đúng profile |
| PAT cho ephemeral | `export GH_TOKEN` | chỉ dùng cho một lệnh `gh api`, có fallback khi lỗi |

Ba điểm cần đọc trước khi dùng PAT: job chạy cùng user với runner nên **đọc được**
`/etc/gh-runner/token`; chỉ đăng ký repo có workflow tin cậy; dùng fine-grained PAT
giới hạn `Administration: write`. Chi tiết trong `template/README.md`.

Terraform không phải đường thứ ba — lý do và skeleton nằm ở
`template/terraform/README.md` (docs-only).

## Dọn dẹp

```bash
./lab.sh destroy          # hỏi xác nhận
./lab.sh destroy --yes    # xóa container + profile, không hỏi
```
