# OPHclinic Espanso

眼科門診用 Espanso v2 設定。ICD-10-CM trigger 只會輸出 code，不會把疾病名稱插入病歷文字。

## 安裝與更新

1. 從 GitHub 最新 Release 下載 `OPHclinic-espanso-v*.zip`。
2. 將 ZIP 放到 portable Espanso 根目錄（與 `espanso.cmd` 同一層）。
3. 在該資料夾開啟 PowerShell，執行：

```powershell
Expand-Archive -LiteralPath .\OPHclinic-espanso-v*.zip -DestinationPath .\ -Force
.\espanso.cmd restart
```

ZIP 只會覆蓋 `.espanso\match\ophthalmology.yml` 和 `.espanso\config\default.yml`。
`default.yml` 由本專案管理，包含全程式的 `key_delay: 10`、`CTRL+ALT+SPACE` 和 `;help` 搜尋列設定。

### 從 v0.3.3 遷移

v1.0.0 起不再有自動更新器。請改用上方 ZIP 流程，不要再執行舊的
`UPDATE_OPHCLINIC.cmd`。確認設定正常後，舊的 `UPDATE_OPHCLINIC.cmd` 與
`.ophclinic` 資料夾可自行刪除。

## 使用指令

- 一般模板以 `;` 開頭，例如 `;init`、`;date`、`;ded`。
- ICD-10-CM 指令以 `;.` 開頭且必須以 `;` 結尾，例如 `;.ded;`、`;.poag;`。
  結尾分號避免短指令在較長指令輸入完成前提早展開。
- 按 `CTRL+ALT+SPACE` 或輸入 `;help` 開啟 Espanso 搜尋列，依 trigger 或輸出文字查詢。
- 所有 ICD trigger、code 與 CMS 官方英文診斷描述見 [ICD-10-CM.md](ICD-10-CM.md)。

多行的 `;init`、`;ded`、CATA 和 LenSx 模板使用 clipboard 輸入模式；ICD 指令不強制輸入模式。

請自行確認每一項模板與 ICD-10-CM code 是否符合當次看診。
