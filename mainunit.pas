unit MainUnit;

{ PasChat - a small HexChat-style IRC client.
  The UI is built in code (BuildUI) so the .lfm stays trivial. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Dialogs, ComCtrls, ExtCtrls, StdCtrls,
  Menus, LCLType, IniFiles, IRCCore;

const
  MaxLines = 2000;

type
  TWinKind = (wkServer, wkChannel, wkQuery);

  TChatWin = class
  public
    Name: string;
    Kind: TWinKind;
    Topic: string;
    Log: TStringList;
    Users: TStringList;
    Unread: Boolean;
    NamesPending: Boolean;
    Node: TTreeNode;
    constructor Create(const AName: string; AKind: TWinKind);
    destructor Destroy; override;
  end;

  TMainForm = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FTree: TTreeView;
    FMemo: TMemo;
    FUsers: TListBox;
    FInput: TEdit;
    FTopic: TEdit;
    FStatus: TStatusBar;
    FTimer: TTimer;
    FConn: TIRCConnection;
    FNick: string;
    FHost: string;
    FRegistered: Boolean;
    FLastServer, FLastNick: string;
    FAccount, FPassword: string;
    FWins: TFPList;
    FServerWin, FCurrent: TChatWin;
    FHistory: TStringList;
    FHistPos: Integer;

    procedure BuildUI;
    function AddMenu(AParent: TMenuItem; const ACaption: string;
      AClick: TNotifyEvent): TMenuItem;
    procedure MenuConnect(Sender: TObject);
    procedure MenuDisconnect(Sender: TObject);
    procedure MenuQuit(Sender: TObject);
    procedure MenuAccount(Sender: TObject);
    procedure PopupClose(Sender: TObject);
    procedure TreeMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure LoadSettings;
    procedure SaveSettings;
    procedure TimerTick(Sender: TObject);
    procedure TreeChange(Sender: TObject; Node: TTreeNode);
    procedure InputKeyPress(Sender: TObject; var Key: Char);
    procedure InputKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure TopicKeyPress(Sender: TObject; var Key: Char);
    procedure UsersDblClick(Sender: TObject);

    function FindWin(const AName: string): TChatWin;
    function EnsureWin(const AName: string; AKind: TWinKind): TChatWin;
    procedure RemoveWin(W: TChatWin);
    procedure SelectWin(W: TChatWin);
    procedure ShowWin(W: TChatWin);
    procedure UpdateNode(W: TChatWin);
    procedure UpdateStatus;
    procedure ScrollMemo;
    procedure AddLine(W: TChatWin; const S: string);

    function UserIndex(W: TChatWin; const ANick: string): Integer;
    procedure UserAdd(W: TChatWin; const ARaw: string; ASort: Boolean);
    function UserRemove(W: TChatWin; const ANick: string): Boolean;
    function UserRename(W: TChatWin; const AOld, ANew: string): Boolean;
    procedure TouchUsers(W: TChatWin);

    procedure ConnectTo(const AHost: string; APort: Integer; const ANick: string);
    procedure SendRaw(const S: string);
    procedure SendText(const S: string);
    procedure ProcessInput(const S: string);
    procedure DoCommand(const ALine: string);
    procedure HandleLine(const ALine: string);
  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

{ ---------- helpers ---------- }

function IsChannelName(const S: string): Boolean;
begin
  Result := (S <> '') and (S[1] in ['#', '&']);
end;

function BareNick(const S: string): string;
var
  I: Integer;
begin
  I := 1;
  while (I <= Length(S)) and (S[I] in ['~', '&', '@', '%', '+']) do Inc(I);
  Result := Copy(S, I, MaxInt);
end;

function NickPrefix(const S: string): string;
begin
  Result := Copy(S, 1, Length(S) - Length(BareNick(S)));
end;

function NickRank(const S: string): Integer;
begin
  Result := 5;
  if S <> '' then
    case S[1] of
      '~': Result := 0;
      '&': Result := 1;
      '@': Result := 2;
      '%': Result := 3;
      '+': Result := 4;
    end;
end;

function CompareUsers(List: TStringList; I1, I2: Integer): Integer;
begin
  Result := NickRank(List[I1]) - NickRank(List[I2]);
  if Result = 0 then
    Result := CompareText(BareNick(List[I1]), BareNick(List[I2]));
end;

{ Accepts: host | host port | host:port | host/port | +host (leading + is ignored).
  Port defaults to 6697 (TLS). }
function ParseServer(const ASpec: string; out AHost: string; out APort: Integer): Boolean;
var
  S: string;
  P: Integer;
begin
  S := Trim(ASpec);
  while (S <> '') and (S[1] in ['+', '/']) do Delete(S, 1, 1);
  S := StringReplace(S, ':', ' ', [rfReplaceAll]);
  S := StringReplace(S, '/', ' ', [rfReplaceAll]);
  S := StringReplace(S, #9, ' ', [rfReplaceAll]);
  AHost := '';
  APort := 6697;
  P := Pos(' ', S);
  if P = 0 then
    AHost := S
  else
  begin
    AHost := Copy(S, 1, P - 1);
    APort := StrToIntDef(Trim(Copy(S, P + 1, MaxInt)), 6697);
  end;
  Result := AHost <> '';
end;

{ ---------- TChatWin ---------- }

constructor TChatWin.Create(const AName: string; AKind: TWinKind);
begin
  inherited Create;
  Name := AName;
  Kind := AKind;
  Log := TStringList.Create;
  Users := TStringList.Create;
end;

destructor TChatWin.Destroy;
begin
  Log.Free;
  Users.Free;
  inherited Destroy;
end;

{ ---------- form lifecycle ---------- }

procedure TMainForm.FormCreate(Sender: TObject);
begin
  Randomize;
  FWins := TFPList.Create;
  FHistory := TStringList.Create;
  FLastServer := 'irc.libera.chat:6697';
  FLastNick := 'PasChat' + IntToStr(Random(900) + 100);
  LoadSettings;
  FNick := FLastNick;
  BuildUI;
  FServerWin := EnsureWin('(server)', wkServer);
  SelectWin(FServerWin);
  AddLine(FServerWin, '* Welcome to PasChat.  IRC > Connect, or type /server irc.libera.chat 6697');
  AddLine(FServerWin, '* Port 6667 = plain text, any other port = TLS.');
  UpdateStatus;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
var
  I: Integer;
begin
  FTimer.Enabled := False;
  FTree.OnChange := nil;
  if FConn <> nil then
  begin
    FConn.RequestQuit('PasChat closing');
    FConn.WaitFor;
    FConn.Free;
    FConn := nil;
  end;
  for I := 0 to FWins.Count - 1 do
    TChatWin(FWins[I]).Free;
  FWins.Free;
  FHistory.Free;
end;

function TMainForm.AddMenu(AParent: TMenuItem; const ACaption: string;
  AClick: TNotifyEvent): TMenuItem;
begin
  Result := TMenuItem.Create(Self);
  Result.Caption := ACaption;
  Result.OnClick := AClick;
  AParent.Add(Result);
end;

procedure TMainForm.BuildUI;
var
  MM: TMainMenu;
  MIrc: TMenuItem;
  Sp: TSplitter;
  Pop: TPopupMenu;
begin
  Caption := 'PasChat';
  Width := 1000;
  Height := 650;
  Position := poScreenCenter;

  MM := TMainMenu.Create(Self);
  MIrc := TMenuItem.Create(Self);
  MIrc.Caption := '&IRC';
  MM.Items.Add(MIrc);
  AddMenu(MIrc, '&Connect...', @MenuConnect);
  AddMenu(MIrc, '&Disconnect', @MenuDisconnect);
  AddMenu(MIrc, '&Account (SASL)...', @MenuAccount);
  AddMenu(MIrc, '-', nil);
  AddMenu(MIrc, '&Quit', @MenuQuit);
  Menu := MM;

  FStatus := TStatusBar.Create(Self);
  FStatus.Parent := Self;
  FStatus.SimplePanel := True;

  // left: server / channel tree
  FTree := TTreeView.Create(Self);
  FTree.Parent := Self;
  FTree.Align := alLeft;
  FTree.Width := 180;
  FTree.ReadOnly := True;
  FTree.HideSelection := False;
  FTree.TabStop := False;
  FTree.OnChange := @TreeChange;
  FTree.OnMouseDown := @TreeMouseDown;
  Pop := TPopupMenu.Create(Self);
  AddMenu(Pop.Items, '&Connect...', @MenuConnect);
  AddMenu(Pop.Items, '&Disconnect', @MenuDisconnect);
  AddMenu(Pop.Items, '&Account (SASL)...', @MenuAccount);
  AddMenu(Pop.Items, '-', nil);
  AddMenu(Pop.Items, 'C&lose window', @PopupClose);
  FTree.PopupMenu := Pop;
  Sp := TSplitter.Create(Self);
  Sp.Parent := Self;
  Sp.Align := alLeft;
  Sp.Left := FTree.Width + 1;

  // right: user list
  FUsers := TListBox.Create(Self);
  FUsers.Parent := Self;
  FUsers.Align := alRight;
  FUsers.Width := 160;
  FUsers.TabStop := False;
  FUsers.OnDblClick := @UsersDblClick;
  Sp := TSplitter.Create(Self);
  Sp.Parent := Self;
  Sp.Align := alRight;
  Sp.Left := FUsers.Left - 1;

  // centre: topic / log / input
  FTopic := TEdit.Create(Self);
  FTopic.Parent := Self;
  FTopic.Align := alTop;
  FTopic.TabStop := False;
  FTopic.OnKeyPress := @TopicKeyPress;

  FInput := TEdit.Create(Self);
  FInput.Parent := Self;
  FInput.Align := alBottom;
  FInput.OnKeyPress := @InputKeyPress;
  FInput.OnKeyDown := @InputKeyDown;

  FMemo := TMemo.Create(Self);
  FMemo.Parent := Self;
  FMemo.Align := alClient;
  FMemo.ReadOnly := True;
  FMemo.ScrollBars := ssAutoVertical;
  FMemo.WordWrap := True;
  FMemo.TabStop := False;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 50;
  FTimer.OnTimer := @TimerTick;
end;

{ ---------- menu ---------- }

procedure TMainForm.MenuConnect(Sender: TObject);
var
  Srv, Nick, Host: string;
  P, Port: Integer;
begin
  if FConn <> nil then
  begin
    ShowMessage('Already connected (or still closing). Disconnect first.');
    Exit;
  end;
  Srv := FLastServer;
  Nick := FLastNick;
  if not InputQuery('Connect', 'Server (host[:port]):', Srv) then Exit;
  if not InputQuery('Connect', 'Nickname:', Nick) then Exit;
  FLastServer := Srv;
  FLastNick := Nick;
  SaveSettings;
  if (not ParseServer(Srv, Host, Port)) or (Trim(Nick) = '') then Exit;
  ConnectTo(Host, Port, Trim(Nick));
end;

procedure TMainForm.MenuDisconnect(Sender: TObject);
begin
  if FConn <> nil then FConn.RequestQuit('Leaving');
end;

procedure TMainForm.MenuQuit(Sender: TObject);
begin
  Close;
end;

{ ---------- settings & account ---------- }

function SettingsFile: string;
begin
  Result := IncludeTrailingPathDelimiter(GetAppConfigDir(False)) + 'paschat.ini';
end;

procedure TMainForm.LoadSettings;
var
  Ini: TIniFile;
begin
  if not FileExists(SettingsFile) then Exit;
  Ini := TIniFile.Create(SettingsFile);
  try
    FLastServer := Ini.ReadString('connection', 'server', FLastServer);
    FLastNick := Ini.ReadString('connection', 'nick', FLastNick);
    FAccount := Ini.ReadString('connection', 'account', '');
    FPassword := Ini.ReadString('connection', 'password', '');
  finally
    Ini.Free;
  end;
end;

procedure TMainForm.SaveSettings;
var
  Ini: TIniFile;
begin
  ForceDirectories(ExtractFilePath(SettingsFile));
  Ini := TIniFile.Create(SettingsFile);
  try
    Ini.WriteString('connection', 'server', FLastServer);
    Ini.WriteString('connection', 'nick', FLastNick);
    Ini.WriteString('connection', 'account', FAccount);
    Ini.WriteString('connection', 'password', FPassword);   // plain text!
  finally
    Ini.Free;
  end;
end;

procedure TMainForm.MenuAccount(Sender: TObject);
var
  Acc, Pw: string;
begin
  Acc := FAccount;
  if not InputQuery('Account (SASL)', 'Account name (leave blank to disable):', Acc) then Exit;
  Acc := Trim(Acc);
  if Acc = '' then
  begin
    FAccount := '';
    FPassword := '';
  end
  else
  begin
    Pw := PasswordBox('Account (SASL)', 'Password for ' + Acc + ' (blank keeps the saved one):');
    if (Pw <> '') or (Acc <> FAccount) then FPassword := Pw;
    FAccount := Acc;
  end;
  SaveSettings;
  if FAccount = '' then
    AddLine(FCurrent, '* SASL disabled.')
  else
    AddLine(FCurrent, '* Account "' + FAccount + '" saved. It is used the next time you connect.');
end;

procedure TMainForm.PopupClose(Sender: TObject);
begin
  DoCommand('/close');
end;

procedure TMainForm.TreeMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  N: TTreeNode;
begin
  if Button = mbRight then
  begin
    N := FTree.GetNodeAt(X, Y);
    if N <> nil then FTree.Selected := N;
  end;
end;

{ ---------- window management ---------- }

function TMainForm.FindWin(const AName: string): TChatWin;
var
  I: Integer;
begin
  for I := 0 to FWins.Count - 1 do
  begin
    Result := TChatWin(FWins[I]);
    if (Result.Kind <> wkServer) and SameText(Result.Name, AName) then Exit;
  end;
  Result := nil;
end;

function TMainForm.EnsureWin(const AName: string; AKind: TWinKind): TChatWin;
begin
  if AKind <> wkServer then
  begin
    Result := FindWin(AName);
    if Result <> nil then Exit;
  end;
  Result := TChatWin.Create(AName, AKind);
  FWins.Add(Result);
  if AKind = wkServer then
    Result.Node := FTree.Items.Add(nil, AName)
  else
    Result.Node := FTree.Items.AddChild(FServerWin.Node, AName);
  Result.Node.Data := Result;
  if FServerWin <> nil then FServerWin.Node.Expand(True);
end;

procedure TMainForm.RemoveWin(W: TChatWin);
begin
  if (W = nil) or (W = FServerWin) then Exit;
  if FCurrent = W then SelectWin(FServerWin);
  FWins.Remove(W);
  W.Node.Delete;
  W.Free;
end;

procedure TMainForm.SelectWin(W: TChatWin);
begin
  if FTree.Selected = W.Node then
    ShowWin(W)
  else
    FTree.Selected := W.Node;      // fires TreeChange -> ShowWin
end;

procedure TMainForm.TreeChange(Sender: TObject; Node: TTreeNode);
begin
  if (Node <> nil) and (Node.Data <> nil) then
    ShowWin(TChatWin(Node.Data));
end;

procedure TMainForm.ShowWin(W: TChatWin);
begin
  FCurrent := W;
  W.Unread := False;
  UpdateNode(W);
  FMemo.Lines.BeginUpdate;
  try
    FMemo.Lines.Assign(W.Log);
  finally
    FMemo.Lines.EndUpdate;
  end;
  ScrollMemo;
  FUsers.Items.Assign(W.Users);
  FTopic.Text := W.Topic;
  if FInput.CanFocus then FInput.SetFocus;
end;

procedure TMainForm.UpdateNode(W: TChatWin);
begin
  if W.Unread then
    W.Node.Text := '* ' + W.Name
  else
    W.Node.Text := W.Name;
end;

procedure TMainForm.UpdateStatus;
begin
  if FConn = nil then
    FStatus.SimpleText := 'Not connected'
  else
    FStatus.SimpleText := Format('Nick: %s   Server: %s', [FNick, FHost]);
end;

procedure TMainForm.ScrollMemo;
begin
  FMemo.SelStart := FMemo.GetTextLen;
  FMemo.SelLength := 0;
end;

procedure TMainForm.AddLine(W: TChatWin; const S: string);
var
  L: string;
begin
  if W = nil then W := FServerWin;
  L := FormatDateTime('hh:nn', Now) + ' ' + S;
  W.Log.Add(L);
  while W.Log.Count > MaxLines do W.Log.Delete(0);
  if W = FCurrent then
  begin
    FMemo.Lines.Add(L);
    while FMemo.Lines.Count > MaxLines do FMemo.Lines.Delete(0);
    ScrollMemo;
  end
  else if not W.Unread then
  begin
    W.Unread := True;
    UpdateNode(W);
  end;
end;

{ ---------- user lists ---------- }

function TMainForm.UserIndex(W: TChatWin; const ANick: string): Integer;
var
  I: Integer;
begin
  for I := 0 to W.Users.Count - 1 do
    if SameText(BareNick(W.Users[I]), ANick) then Exit(I);
  Result := -1;
end;

procedure TMainForm.TouchUsers(W: TChatWin);
begin
  if W = FCurrent then FUsers.Items.Assign(W.Users);
end;

procedure TMainForm.UserAdd(W: TChatWin; const ARaw: string; ASort: Boolean);
var
  I: Integer;
begin
  I := UserIndex(W, BareNick(ARaw));
  if I >= 0 then W.Users.Delete(I);
  W.Users.Add(ARaw);
  if ASort then
  begin
    W.Users.CustomSort(@CompareUsers);
    TouchUsers(W);
  end;
end;

function TMainForm.UserRemove(W: TChatWin; const ANick: string): Boolean;
var
  I: Integer;
begin
  I := UserIndex(W, ANick);
  Result := I >= 0;
  if Result then
  begin
    W.Users.Delete(I);
    TouchUsers(W);
  end;
end;

function TMainForm.UserRename(W: TChatWin; const AOld, ANew: string): Boolean;
var
  I: Integer;
begin
  I := UserIndex(W, AOld);
  Result := I >= 0;
  if Result then
  begin
    W.Users[I] := NickPrefix(W.Users[I]) + ANew;
    W.Users.CustomSort(@CompareUsers);
    TouchUsers(W);
  end;
end;

procedure TMainForm.UsersDblClick(Sender: TObject);
var
  N: string;
begin
  if FUsers.ItemIndex < 0 then Exit;
  N := BareNick(FUsers.Items[FUsers.ItemIndex]);
  if not SameText(N, FNick) then
    SelectWin(EnsureWin(N, wkQuery));
end;

{ ---------- connection ---------- }

procedure TMainForm.ConnectTo(const AHost: string; APort: Integer;
  const ANick: string);
begin
  if FConn <> nil then
  begin
    AddLine(FCurrent, '* Already connected (or still closing). Use /quit first.');
    Exit;
  end;
  FNick := ANick;
  FHost := AHost;
  FRegistered := False;
  if FAccount <> '' then
    AddLine(FServerWin, '* Will authenticate as ' + FAccount + ' (SASL).');
  FConn := TIRCConnection.Create(AHost, Word(APort), APort <> 6667, ANick,
    FAccount, FPassword);
  FConn.Start;
  UpdateStatus;
end;

procedure TMainForm.TimerTick(Sender: TObject);
var
  K: Char;
  S: string;
  N: Integer;
  Finished: Boolean;
begin
  if FConn = nil then Exit;
  Finished := FConn.Done;          // read BEFORE draining (see note in IRCCore)
  N := 0;
  while (N < 200) and FConn.PopLine(K, S) do
  begin
    Inc(N);
    if K = 'L' then
      HandleLine(S)
    else
      AddLine(FServerWin, '* ' + S);
  end;
  if Finished and (N < 200) then
  begin
    FConn.Free;
    FConn := nil;
    FRegistered := False;
    AddLine(FServerWin, '* Disconnected.');
    UpdateStatus;
  end;
end;

procedure TMainForm.SendRaw(const S: string);
begin
  if FConn = nil then
    AddLine(FCurrent, '* Not connected.')
  else
    FConn.Send(S);
end;

procedure TMainForm.SendText(const S: string);
var
  Rest, Chunk: string;
  Cut: Integer;
begin
  if FCurrent.Kind = wkServer then
  begin
    AddLine(FCurrent, '* You are not in a channel. Try /join #channel');
    Exit;
  end;
  if FConn = nil then
  begin
    AddLine(FCurrent, '* Not connected.');
    Exit;
  end;
  Rest := S;
  while Rest <> '' do
  begin
    Cut := 400;                    // IRC lines max 512 bytes incl. overhead
    if Length(Rest) > Cut then
    begin
      // don't cut in the middle of a UTF-8 sequence
      while (Cut > 1) and ((Ord(Rest[Cut + 1]) and $C0) = $80) do Dec(Cut);
    end
    else
      Cut := Length(Rest);
    Chunk := Copy(Rest, 1, Cut);
    Delete(Rest, 1, Cut);
    FConn.Send('PRIVMSG ' + FCurrent.Name + ' :' + Chunk);
    AddLine(FCurrent, '<' + FNick + '> ' + Chunk);
  end;
end;

{ ---------- input ---------- }

procedure TMainForm.ProcessInput(const S: string);
begin
  if (S[1] = '/') and (Copy(S, 1, 2) <> '//') then
    DoCommand(S)
  else if Copy(S, 1, 2) = '//' then
    SendText(Copy(S, 2, MaxInt))
  else
    SendText(S);
end;

procedure TMainForm.InputKeyPress(Sender: TObject; var Key: Char);
var
  S: string;
begin
  if Key <> #13 then Exit;
  Key := #0;
  S := FInput.Text;
  FInput.Clear;
  if S = '' then Exit;
  FHistory.Add(S);
  FHistPos := FHistory.Count;
  ProcessInput(S);
end;

procedure TMainForm.InputKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
var
  T, Word_, Pfx: string;
  P, I: Integer;
begin
  case Key of
    VK_UP:
      begin
        if FHistPos > 0 then
        begin
          Dec(FHistPos);
          FInput.Text := FHistory[FHistPos];
          FInput.SelStart := Length(FInput.Text);
        end;
        Key := 0;
      end;
    VK_DOWN:
      begin
        if FHistPos < FHistory.Count - 1 then
        begin
          Inc(FHistPos);
          FInput.Text := FHistory[FHistPos];
          FInput.SelStart := Length(FInput.Text);
        end
        else
        begin
          FHistPos := FHistory.Count;
          FInput.Clear;
        end;
        Key := 0;
      end;
    VK_TAB:
      begin
        // nick completion (first match)
        Key := 0;
        T := FInput.Text;
        P := Length(T);
        while (P > 0) and (T[P] <> ' ') do Dec(P);
        Word_ := Copy(T, P + 1, MaxInt);
        if Word_ = '' then Exit;
        for I := 0 to FCurrent.Users.Count - 1 do
        begin
          Pfx := BareNick(FCurrent.Users[I]);
          if SameText(Copy(Pfx, 1, Length(Word_)), Word_) then
          begin
            T := Copy(T, 1, P) + Pfx;
            if P = 0 then T := T + ': ' else T := T + ' ';
            FInput.Text := T;
            FInput.SelStart := Length(T);
            Break;
          end;
        end;
      end;
  end;
end;

procedure TMainForm.TopicKeyPress(Sender: TObject; var Key: Char);
begin
  if Key <> #13 then Exit;
  Key := #0;
  if FCurrent.Kind = wkChannel then
    SendRaw('TOPIC ' + FCurrent.Name + ' :' + FTopic.Text);
end;

procedure TMainForm.DoCommand(const ALine: string);
var
  S, Cmd, Arg, Tgt, Msg, Host: string;
  P, Port: Integer;
  W: TChatWin;
begin
  S := Copy(ALine, 2, MaxInt);
  P := Pos(' ', S);
  if P = 0 then
  begin
    Cmd := UpperCase(S);
    Arg := '';
  end
  else
  begin
    Cmd := UpperCase(Copy(S, 1, P - 1));
    Arg := Trim(Copy(S, P + 1, MaxInt));
  end;

  case Cmd of
    'SERVER':
      begin
        if not ParseServer(Arg, Host, Port) then
          AddLine(FCurrent, '* Usage: /server host [port]')
        else
        begin
          SelectWin(FServerWin);          // so connection progress is visible
          ConnectTo(Host, Port, FLastNick);
        end;
      end;
    'JOIN', 'J':
      begin
        if Arg = '' then
          AddLine(FCurrent, '* Usage: /join #channel [key]')
        else
        begin
          if not IsChannelName(Arg) then Arg := '#' + Arg;
          SendRaw('JOIN ' + Arg);
        end;
      end;
    'PART', 'LEAVE':
      begin
        if Arg = '' then Arg := FCurrent.Name;
        if IsChannelName(Arg) then SendRaw('PART ' + Arg)
        else AddLine(FCurrent, '* Not a channel.');
      end;
    'CLOSE':
      begin
        if FCurrent.Kind = wkChannel then SendRaw('PART ' + FCurrent.Name);
        RemoveWin(FCurrent);
      end;
    'MSG':
      begin
        P := Pos(' ', Arg);
        if P = 0 then
          AddLine(FCurrent, '* Usage: /msg target text')
        else
        begin
          Tgt := Copy(Arg, 1, P - 1);
          Msg := Copy(Arg, P + 1, MaxInt);
          SendRaw('PRIVMSG ' + Tgt + ' :' + Msg);
          if IsChannelName(Tgt) then W := FindWin(Tgt)
          else W := EnsureWin(Tgt, wkQuery);
          AddLine(W, '<' + FNick + '> ' + Msg);
        end;
      end;
    'QUERY':
      begin
        if Arg <> '' then SelectWin(EnsureWin(Arg, wkQuery));
      end;
    'ME':
      begin
        if FCurrent.Kind = wkServer then
          AddLine(FCurrent, '* Not in a channel or query.')
        else
        begin
          SendRaw('PRIVMSG ' + FCurrent.Name + ' :' + #1 + 'ACTION ' + Arg + #1);
          AddLine(FCurrent, '* ' + FNick + ' ' + Arg);
        end;
      end;
    'NICK':
      begin
        if Arg <> '' then
        begin
          FLastNick := Arg;
          SendRaw('NICK ' + Arg);
        end;
      end;
    'TOPIC':
      begin
        if FCurrent.Kind <> wkChannel then
          AddLine(FCurrent, '* Not in a channel.')
        else if Arg = '' then
          SendRaw('TOPIC ' + FCurrent.Name)
        else
          SendRaw('TOPIC ' + FCurrent.Name + ' :' + Arg);
      end;
    'QUIT', 'DISCONNECT':
      begin
        if FConn <> nil then
        begin
          if Arg = '' then Arg := 'Leaving';
          FConn.RequestQuit(Arg);
        end;
      end;
    'RAW', 'QUOTE':
      SendRaw(Arg);
    'CLEAR':
      begin
        FCurrent.Log.Clear;
        FMemo.Clear;
      end;
  else
    // like HexChat: unknown commands go to the server as-is
    SendRaw(Cmd + ' ' + Arg);
  end;
end;

{ ---------- server -> UI ---------- }

procedure TMainForm.HandleLine(const ALine: string);
var
  M: TIRCMessage;
  Nick, Target, Txt, Chan, NewNick, Who: string;
  W: TChatWin;
  I: Integer;
  Names: TStringList;

  function Prm(AIndex: Integer): string;
  begin
    if AIndex < Length(M.Params) then Result := M.Params[AIndex]
    else Result := '';
  end;

begin
  M := ParseIRCLine(ALine);
  Nick := NickFromPrefix(M.Prefix);

  if M.Command = 'PRIVMSG' then
  begin
    Target := Prm(0);
    Txt := Prm(1);
    if IsChannelName(Target) then W := EnsureWin(Target, wkChannel)
    else if Nick = '' then W := FServerWin
    else W := EnsureWin(Nick, wkQuery);

    if (Length(Txt) > 1) and (Txt[1] = #1) then
    begin
      Txt := Copy(Txt, 2, MaxInt);
      if (Txt <> '') and (Txt[Length(Txt)] = #1) then
        SetLength(Txt, Length(Txt) - 1);
      if Copy(Txt, 1, 7) = 'ACTION ' then
        AddLine(W, '* ' + Nick + ' ' + StripFormatting(Copy(Txt, 8, MaxInt)))
      else
      begin
        if Txt = 'VERSION' then
          SendRaw('NOTICE ' + Nick + ' :' + #1 + 'VERSION PasChat 0.1' + #1);
        AddLine(FServerWin, '* CTCP ' + Txt + ' from ' + Nick);
      end;
    end
    else
      AddLine(W, '<' + Nick + '> ' + StripFormatting(Txt));
  end

  else if M.Command = 'NOTICE' then
  begin
    if Nick = '' then
      AddLine(FServerWin, '-' + M.Prefix + '- ' + StripFormatting(Prm(1)))
    else
      AddLine(FServerWin, '-' + Nick + '- ' + StripFormatting(Prm(1)));
  end

  else if M.Command = 'JOIN' then
  begin
    Chan := Prm(0);
    if SameText(Nick, FNick) then
    begin
      W := EnsureWin(Chan, wkChannel);
      W.Users.Clear;
      SelectWin(W);
      AddLine(W, '* Now talking on ' + Chan);
    end
    else
    begin
      W := FindWin(Chan);
      if W <> nil then
      begin
        UserAdd(W, Nick, True);
        AddLine(W, '* ' + Nick + ' (' + M.Prefix + ') has joined');
      end;
    end;
  end

  else if M.Command = 'PART' then
  begin
    Chan := Prm(0);
    W := FindWin(Chan);
    if W <> nil then
    begin
      if SameText(Nick, FNick) then
        RemoveWin(W)
      else
      begin
        UserRemove(W, Nick);
        AddLine(W, '* ' + Nick + ' has left (' + Prm(1) + ')');
      end;
    end;
  end

  else if M.Command = 'QUIT' then
  begin
    for I := 0 to FWins.Count - 1 do
    begin
      W := TChatWin(FWins[I]);
      if W.Kind = wkServer then Continue;
      if UserRemove(W, Nick) or ((W.Kind = wkQuery) and SameText(W.Name, Nick)) then
        AddLine(W, '* ' + Nick + ' has quit (' + StripFormatting(Prm(0)) + ')');
    end;
  end

  else if M.Command = 'NICK' then
  begin
    NewNick := Prm(0);
    if SameText(Nick, FNick) then
    begin
      FNick := NewNick;
      UpdateStatus;
    end;
    for I := 0 to FWins.Count - 1 do
    begin
      W := TChatWin(FWins[I]);
      if W.Kind = wkServer then Continue;
      if UserRename(W, Nick, NewNick) then
        AddLine(W, '* ' + Nick + ' is now known as ' + NewNick)
      else if (W.Kind = wkQuery) and SameText(W.Name, Nick) then
      begin
        W.Name := NewNick;
        UpdateNode(W);
        AddLine(W, '* ' + Nick + ' is now known as ' + NewNick);
      end;
    end;
  end

  else if M.Command = 'KICK' then
  begin
    W := FindWin(Prm(0));
    if W <> nil then
    begin
      Who := Prm(1);
      UserRemove(W, Who);
      AddLine(W, '* ' + Who + ' was kicked by ' + Nick + ' (' + StripFormatting(Prm(2)) + ')');
    end;
  end

  else if M.Command = 'TOPIC' then
  begin
    W := FindWin(Prm(0));
    if W <> nil then
    begin
      W.Topic := StripFormatting(Prm(1));
      if W = FCurrent then FTopic.Text := W.Topic;
      AddLine(W, '* ' + Nick + ' changed the topic to: ' + W.Topic);
    end;
  end

  else if M.Command = 'MODE' then
  begin
    if IsChannelName(Prm(0)) then
    begin
      W := FindWin(Prm(0));
      if W <> nil then
      begin
        AddLine(W, '* ' + Nick + ' sets mode ' + JoinParams(M, 1));
        // lazy way to keep @/+ prefixes correct: ask for NAMES again
        if Length(M.Params) > 2 then SendRaw('NAMES ' + W.Name);
      end;
    end
    else
      AddLine(FServerWin, '* Mode ' + JoinParams(M, 0));
  end

  else if M.Command = 'ERROR' then
    AddLine(FServerWin, '* ERROR: ' + Prm(0))

  { ---- numerics ---- }
  else if M.Command = '001' then
  begin
    FNick := Prm(0);
    FRegistered := True;
    UpdateStatus;
    AddLine(FServerWin, StripFormatting(Prm(1)));
  end
  else if M.Command = '332' then          // topic on join
  begin
    W := FindWin(Prm(1));
    if W <> nil then
    begin
      W.Topic := StripFormatting(Prm(2));
      if W = FCurrent then FTopic.Text := W.Topic;
      AddLine(W, '* Topic is: ' + W.Topic);
    end;
  end
  else if M.Command = '353' then          // NAMES reply
  begin
    W := FindWin(Prm(2));
    if W <> nil then
    begin
      if not W.NamesPending then
      begin
        W.Users.Clear;
        W.NamesPending := True;
      end;
      Names := TStringList.Create;
      try
        Names.Delimiter := ' ';
        Names.StrictDelimiter := True;
        Names.DelimitedText := Prm(3);
        for I := 0 to Names.Count - 1 do
          if Names[I] <> '' then UserAdd(W, Names[I], False);
      finally
        Names.Free;
      end;
      W.Users.CustomSort(@CompareUsers);
      TouchUsers(W);
    end;
  end
  else if M.Command = '366' then          // end of NAMES
  begin
    W := FindWin(Prm(1));
    if W <> nil then
    begin
      W.NamesPending := False;
      TouchUsers(W);
    end;
  end
  else if M.Command = '433' then          // nick in use
  begin
    AddLine(FServerWin, '* Nickname ' + Prm(1) + ' is already in use.');
    if not FRegistered then
    begin
      FNick := Prm(1) + '_';
      SendRaw('NICK ' + FNick);
      UpdateStatus;
    end;
  end
  else if (Length(M.Command) = 3) and (M.Command[1] in ['0'..'9']) then
    AddLine(FServerWin, StripFormatting(JoinParams(M, 1)));
end;

end.
