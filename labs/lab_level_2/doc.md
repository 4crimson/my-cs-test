**Смысл** — от начала до конца воспроизвести *живое профилирование control-plane Kubernetes*, а именно **`kube-apiserver`**, и визуализировать, куда уходит CPU-время в реальном минимальном кластере, собранном тобой вручную.

То есть ты фактически сделал **свой собственный `kubectl flame` + `perf` пайплайн**, но без Helm, без Prometheus — только системно и низкоуровнево.

---

## 📁 Что в `labs/lab_level_2`

Там цепочка bash-скриптов, каждая — отдельный этап.

| Скрипт                    | Назначение                                                             | Что делает                                                                                                                                                                                                                                                                                |
| :------------------------ | :--------------------------------------------------------------------- | :---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `01_debug_pod.sh`         | Создание **debug-контейнера** с `hostPID`, `hostNetwork`, `privileged` | Даёт возможность "видеть" процессы хоста изнутри pod’а (в том числе `kube-apiserver`) и запускать системные инструменты (`perf`, `strace`, `nsenter` и т.д.).                                                                                                                             |
| `01a_perf_runner.sh`      | Лёгкий **perf-runner** на `alpine`                                     | Поднимает временный pod, где можно быстро поставить `perf` и `curl`. Он тоже `privileged` и видит процессы ноды. Это твоя площадка для профилирования ядра.                                                                                                                               |
| `02_profile_apiserver.sh` | Основной **профилировщик**                                             | <ul><li>находит PID `kube-apiserver` на хосте;</li><li>проверяет `kernel.perf_event_paranoid` и `kptr_restrict`;</li><li>запускает `perf record -F 99 -g -p <PID> -- sleep 60`;</li><li>собирает 99 сэмплов в секунду в `/tmp/apiserver.perf.data`.</li></ul>                             |
| `03_flamegraph.sh`        | Построение **FlameGraph**                                              | <ul><li>ставит `perl` + скачивает инструменты [Brendan Gregg FlameGraph](https://github.com/brendangregg/FlameGraph);</li><li>прогоняет `perf script` → `stackcollapse-perf.pl` → `flamegraph.pl`;</li><li>создаёт `/tmp/flame.svg` — интерактивную визуализацию стека вызовов.</li></ul> |
| `04_fetch_and_commit.sh`  | Автоматическая выгрузка и фиксация результата                          | <ul><li>копирует `flame.svg` с pod’а (`kubectl cp`);</li><li>сохраняет локально с таймстемпом;</li><li>`git add/commit/push` → репозиторий (`flame-20251007-....svg`).</li></ul>                                                                                                          |

---

## ⚙️ Что реально произошло

1. **Мини-кластер** (`start`-скрипт из `mini-k8s`) поднял control-plane (etcd, apiserver, controller, scheduler) как static pods через kubelet.
2. **`perf-runner`** вошёл в `hostPID`-неймспейс, получил доступ к процессу `kube-apiserver` и снял выборку стека (`perf_event_open`).
3. **Данные** `/tmp/apiserver.perf.data` (~50 KB) содержат ~6000 сэмплов стека за минуту.
4. **FlameGraph** визуализировал их: прямоугольники = функции; ширина = доля CPU-времени; нижний слой — “корни” вызовов, верхний — leaf-функции.
5. **Git-пайплайн** выгрузил SVG в репо, сохранив версию анализа прямо вместе с кодом (идея — “Infrastructure + Profiling as Code”).

---

## 🔥 Что показывает FlameGraph

Если открыть `flame-20251007-….svg` в браузере:

* Широкие блоки внизу — “долгие” функции (например, `runtime.schedule`, `syscall.Syscall`, `k8s.io/apiserver/pkg/endpoints/handlers`).
* Можно кликать, искать (`Ctrl+F`) — смотреть hot-spots: например, `storage/etcd3`, `admission`, `authentication`, `serializer`, `runtime.gcBgMarkWorker`.
* Это реальный профиль CPU-нагрузки твоего API-сервера.

---

## 🧠 Зачем это нужно

Ты построил **низкоуровневую систему performance-анализа Kubernetes**, пригодную для:

* 🧩 Отладки control-plane и CNI-сетей;
* 🩺 Измерения реальной нагрузки (`etcd`, `scheduler`, `apiserver`);
* 📊 Построения собственной метрики performance (собрал → flamegraph → выгрузил → commit);
* 🔬 Освоения инструментов `perf`, `eBPF`, и понимания, *как устроен ядро + kubelet + apiserver*.
