# Repair-codex-pet-overlay

[English version](README.md)

Codex Desktopのアバター／ペットオーバーレイで、画面上の表示位置と
Windowsのマウスクリック判定領域がずれてしまう問題に対する、
Windows PowerShell用の回避スクリプトだよ。

このスクリプトは `app.asar` やペット画像を変更しない。保存されている
ペット位置をもとに、起動中のオーバーレイウィンドウの入力スタイルと
クリック判定領域を調整する。上流のWindows版オーバーレイ問題が修正される
まで使うことを想定した、元に戻せる回避策だね。

## 必要環境

- Windows 10 / 11
- Codex Desktop（パッケージ化されたプロセス名は通常 `ChatGPT.exe`）
- Windows PowerShell 5.1

スクリプトが使うのはローカルのWindows APIだけ。ネットワーク通信や
GitHubの認証情報の読み取りは行わない。

## クイックスタート

このREADMEがあるディレクトリでPowerShellを開き、次を実行する。

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\repair-codex-pet-overlay.ps1
```

スクリプトは手動起動の単発動作。表示中のCodexペットオーバーレイが現れる
まで最大300秒待機し、見つかったら一度だけ補正して終了する。Codexより先に
起動して待機させても大丈夫。待機時間を変更する場合は次のようにする。

```powershell
.\repair-codex-pet-overlay.ps1 -WaitForOverlaySeconds 120
```

既定では、現在のペット位置を次のファイルから読み取る。

```text
%USERPROFILE%\.codex\.codex-global-state.json
```

ウィンドウ検出のサイズ条件は、候補ウィンドウが存在するモニターに合わせて
調整される。固定の1000ピクセル以上のウィンドウ高さを要求しないため、
DPI仮想化されたPowerShellから1920x1200が1536x960として報告される環境にも
対応している。複数の解像度のモニターも個別に扱い、解像度や拡大率を手入力
する必要はない。

保存された表示位置は、Codexの状態にディスプレイ別の値があれば
（`byResolution` または `byDisplayId`）そこから選択する。選択した位置は、
実際に存在するオーバーレイウィンドウ自身の座標系へ変換される。解像度、
DPIの倍率、モニターサイズを設定値として入力することはなく、実行時に
現在のHWNDと保存済みのディスプレイ情報を調べる。

補正領域は起動中のオーバーレイ全体の横幅を使うため、吹き出しが横に広がって
も切り取られにくい。上下の範囲は実際のウィンドウ高さと、変換結果として
考えられるすべてのペット位置から計算する。Windowsの `SetWindowRgn` は
マウス入力だけでなく描画も制限するため、ペットと吹き出しの両方を覆う領域が
必要になる。

スクリプトはCodexを起動したり変更したりしない。補正に成功すると
`applied ...` を表示して終了コード0で終了する。待機時間内にオーバーレイや
保存位置を取得できなければ、最後の結果を表示し、診断ログを書いて終了コード1
で終了する。バックグラウンドで監視し続けるプロセスは残らない。

以前の回避策のあとにペットが表示されない場合は、手動補正を実行する前に
Codexを一度再起動する。スクリプトが入力領域を補正するには、アプリが表示中の
オーバーレイウィンドウを作り直している必要がある。Codexより先にスクリプトを
起動して待たせることも、ペットを設定画面で一度非表示にしてから表示し直した
あとに実行することもできる。

## 別の環境で座標を指定する場合

通常は `-AnchorX` と `-AnchorY` を省略する。スクリプトがCodexの現在値を
自動的に追従する。保存値が古い場合は、2つの値を組み合わせて指定する。

```powershell
.\repair-codex-pet-overlay.ps1 -AnchorX 2200 -AnchorY 1200
.\repair-codex-pet-overlay.ps1 -WaitForOverlaySeconds 300 -AnchorX 2200 -AnchorY 1200
```

ここで指定するのは、Codexが保存している表示座標系の絶対スクリーン座標であり、
縮小されたスクリーンショットから読み取った座標ではない。2560x1440の画面なら
通常は左上が `(0, 0)`。左側にモニターがある構成では、Xが負の値になることも
ある。画像サイズから推測せず、Codexが保持している値を使う。

保存値を確認するには、次を実行する。

```powershell
$statePath = Join-Path $env:USERPROFILE '.codex\.codex-global-state.json'
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$state.'electron-avatar-overlay-bounds' | Format-List
```

入力するのは `x` と `y` の値。ペットを移動している最中はJSONが書き換えられて
いる可能性があるため、移動が終わってからもう一度実行する。

## 手動起動のみ

この版では常時監視を意図的に廃止しており、`-Watch` は受け付けない。
タスクスケジューラには登録しないこと。Codexの起動前または起動後に手動で
スクリプトを実行すると、最大5分間オーバーレイを待ち、1回補正したあと終了する。
アプリを再起動したりオーバーレイを作り直したりしたあとに再発した場合は、
必要なタイミングでスクリプトをもう一度実行する。

## 復元

現在表示されているオーバーレイから、このスクリプトの変更を外すには次を実行する。

```powershell
.\repair-codex-pet-overlay.ps1 -Restore
```

その後Codexを再起動して、アプリ本来のレイヤードウィンドウ設定と
マウス入力ポリシーを復元させる。補正プロセスは単発動作なので、成功または
タイムアウト後には終了している。

## プライバシーとリポジトリの範囲

リポジトリには、PowerShellスクリプト、README、無視設定ファイルだけを含める。
スクリプト自体にユーザー名、ローカルの絶対パス、IPアドレス、トークン、
スクリーンショット、ペット画像、Codexの状態スナップショットは含めない。
実行時には現在のユーザープロファイルを動的に解決してローカルのオーバーレイ
状態を読み取り、エラーが発生した場合だけ
`repair-codex-pet-overlay.log` を書き出す。

状態ファイル、スクリーンショット、実行時ログはコミットしないこと。
これらは、該当するものについて `.gitignore` で除外される。

## 上流の関連情報

- [Codex Desktop pet overlay discussion](https://community.openai.com/t/codex-desktop-pet-reacts-to-hover-but-cannot-be-dragged-on-windows/1393368)
- [OpenAI Codex issue #34227](https://github.com/openai/codex/issues/34227)
- [OpenAI Codex issue #41465](https://github.com/openai/codex/issues/41465)
