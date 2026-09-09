# Repair-codex-pet-overlay

[English version](README.md)

Codex Desktopのペットが表示されているのにクリックできない問題を補正する、Windows PowerShell用の回避スクリプト。

## 必要環境

- Windows 10 / 11
- Codex Desktop
- Windows PowerShell 5.1

## 実行方法

エクスプローラーの「PowerShellで実行」ではなく、PowerShellを開いて実行する。

READMEがあるディレクトリで次を実行する。

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\repair-codex-pet-overlay.ps1
```

スクリプトは単発動作で、ペット用オーバーレイを最大5分間待機する。Codexの起動前に実行して待機させることも、Codexの起動後に実行することもできる。補正に成功すると終了する。

成功時は `applied ...` と表示され、終了コードは0になる。オーバーレイを検出できない場合は、待機後に `overlay-not-found` を含むメッセージを表示し、終了コード1になる。

待機時間を変更する場合は `-WaitForOverlaySeconds` を指定する。

```powershell
.\repair-codex-pet-overlay.ps1 -WaitForOverlaySeconds 120
```

解像度や拡大率は自動処理されるため、通常は座標の入力は不要。ペットの保存位置が古い場合のみ、`-AnchorX` と `-AnchorY` をセットで指定する。

```powershell
.\repair-codex-pet-overlay.ps1 -AnchorX 2200 -AnchorY 1200
```

座標にはスクリーンショットの座標ではなく、Codexが保存している `x` と `y` の値を使用する。保存値は次で確認できる。

```powershell
$statePath = Join-Path $env:USERPROFILE '.codex\.codex-global-state.json'
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$state.'electron-avatar-overlay-bounds' | Format-List
```

この版は手動起動専用で、`-Watch` は使用できない。タスクスケジューラへの登録は不要。

ペットが表示されない場合は、Codexを再起動するか、設定画面でペットを一度非表示にしてから再表示し、スクリプトを再実行する。

## 復元

スクリプトによる補正を外す場合は次を実行する。

```powershell
.\repair-codex-pet-overlay.ps1 -Restore
```

実行後にCodexを再起動する。

## 参考情報

- [Codex Desktop pet overlay discussion](https://community.openai.com/t/codex-desktop-pet-reacts-to-hover-but-cannot-be-dragged-on-windows/1393368)
- [OpenAI Codex issue #34227](https://github.com/openai/codex/issues/34227)
- [OpenAI Codex issue #41465](https://github.com/openai/codex/issues/41465)
