# 維護與發版

Python 只供 GitHub Actions 與 repo 維護使用；portable Espanso 使用者不需要安裝 Python。

## 維護檔案

- `scripts/validate_config.py`：驗證設定、CMS 2026 ICD-10-CM code、ICD 參考表與敏感資料。
- `scripts/build_release.py`：建立可直接解壓到 portable 根目錄的 Release ZIP 與 SHA-256 檔案。
- `.github/workflows/validate-and-release.yml`：在 GitHub runner 執行驗證並依 tag 建立 Release。

## 變更 ICD 設定

安裝維護相依套件後，先重新產生 ICD 對照表，再驗證：

```powershell
python -m pip install --requirement requirements-dev.txt
python .\scripts\validate_config.py --write-icd-reference
python .\scripts\validate_config.py
```

`ICD-10-CM.md` 使用 CMS April 1, 2026 官方英文描述；疾病名稱只供檢閱，不能加入 Espanso 的 ICD replacement。

## 發版

1. 更新 `_manifest.yml` 的 SemVer 版本。
2. 執行：

```powershell
python .\scripts\validate_config.py
python .\scripts\build_release.py --tag v1.0.0 --output dist
```

3. 提交並推送 `main`，再建立同版本 tag，例如 `v1.0.0`。

GitHub Actions 會驗證設定、建立 `OPHclinic-espanso-v1.0.0.zip` 與 `.sha256`，並發佈 GitHub Release。
