unit IRCCore;

{ Minimal IRC connection layer.
  - TIRCConnection runs a worker thread that owns the socket (reads AND writes),
    so SSL is never used from two threads at once.
  - Everything the thread receives is queued; the GUI polls PopLine from a TTimer. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, base64, ssockets, sslsockets, opensslsockets;

type
  TIRCMessage = record
    Prefix: string;
    Command: string;
    Params: array of string;   // last element is the "trailing" parameter
  end;

  TIRCConnection = class(TThread)
  private
    FHost: string;
    FPort: Word;
    FUseSSL: Boolean;
    FNick, FUser, FRealName, FPassword, FAccount: string;
    FSaslBusy: Boolean;
    FLock: TCriticalSection;
    FIn, FOut: TStringList;
    FQuit: Boolean;
    FDone: Boolean;
    procedure Post(Kind: Char; const S: string);
    function PopOut(out S: string): Boolean;
    procedure WriteLine(ASock: TInetSocket; const S: string);
    procedure HandleSasl(ASock: TInetSocket; const ALine: string);
  protected
    procedure Execute; override;
  public
    constructor Create(const AHost: string; APort: Word; AUseSSL: Boolean;
      const ANick, AAccount, APassword: string);
    destructor Destroy; override;
    procedure Send(const ALine: string);
    procedure RequestQuit(const AMsg: string);
    { Kind = 'L' (raw server line) or 'S' (status text from this unit) }
    function PopLine(out Kind: Char; out S: string): Boolean;
    property Done: Boolean read FDone;
  end;

function ParseIRCLine(const ALine: string): TIRCMessage;
function NickFromPrefix(const APrefix: string): string;
function JoinParams(const M: TIRCMessage; AFrom: Integer): string;
function StripFormatting(const S: string): string;

implementation

procedure AddParam(var M: TIRCMessage; const S: string);
begin
  SetLength(M.Params, Length(M.Params) + 1);
  M.Params[High(M.Params)] := S;
end;

function ParseIRCLine(const ALine: string): TIRCMessage;
var
  S: string;
  P: Integer;
begin
  Result.Prefix := '';
  Result.Command := '';
  SetLength(Result.Params, 0);
  S := ALine;

  // IRCv3 message tags: skip them
  if (S <> '') and (S[1] = '@') then
  begin
    P := Pos(' ', S);
    if P = 0 then Exit;
    Delete(S, 1, P);
  end;

  if (S <> '') and (S[1] = ':') then
  begin
    P := Pos(' ', S);
    if P = 0 then
    begin
      Result.Prefix := Copy(S, 2, MaxInt);
      Exit;
    end;
    Result.Prefix := Copy(S, 2, P - 2);
    Delete(S, 1, P);
  end;

  P := Pos(' ', S);
  if P = 0 then
  begin
    Result.Command := UpperCase(S);
    Exit;
  end;
  Result.Command := UpperCase(Copy(S, 1, P - 1));
  Delete(S, 1, P);

  while S <> '' do
  begin
    if S[1] = ':' then
    begin
      AddParam(Result, Copy(S, 2, MaxInt));
      Break;
    end;
    P := Pos(' ', S);
    if P = 0 then
    begin
      AddParam(Result, S);
      Break;
    end;
    AddParam(Result, Copy(S, 1, P - 1));
    Delete(S, 1, P);
  end;
end;

function NickFromPrefix(const APrefix: string): string;
var
  P: Integer;
begin
  P := Pos('!', APrefix);
  if P > 0 then
    Result := Copy(APrefix, 1, P - 1)
  else if Pos('.', APrefix) > 0 then
    Result := ''            // looks like a server name
  else
    Result := APrefix;
end;

function JoinParams(const M: TIRCMessage; AFrom: Integer): string;
var
  I: Integer;
begin
  Result := '';
  for I := AFrom to High(M.Params) do
  begin
    if Result <> '' then Result := Result + ' ';
    Result := Result + M.Params[I];
  end;
end;

function StripFormatting(const S: string): string;
var
  I, N: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    case S[I] of
      #2, #15, #22, #29, #30, #31: Inc(I);
      #3:
        begin
          Inc(I);
          N := 0;
          while (I <= Length(S)) and (S[I] in ['0'..'9']) and (N < 2) do
          begin
            Inc(I);
            Inc(N);
          end;
          if (I < Length(S)) and (S[I] = ',') and (S[I + 1] in ['0'..'9']) then
          begin
            Inc(I);
            N := 0;
            while (I <= Length(S)) and (S[I] in ['0'..'9']) and (N < 2) do
            begin
              Inc(I);
              Inc(N);
            end;
          end;
        end;
    else
      begin
        Result := Result + S[I];
        Inc(I);
      end;
    end;
  end;
end;

{ TIRCConnection }

constructor TIRCConnection.Create(const AHost: string; APort: Word;
  AUseSSL: Boolean; const ANick, AAccount, APassword: string);
begin
  inherited Create(True);          // created suspended; caller calls Start
  FreeOnTerminate := False;
  FHost := AHost;
  FPort := APort;
  FUseSSL := AUseSSL;
  FNick := ANick;
  FUser := 'paschat';
  FRealName := 'PasChat user';
  FPassword := APassword;
  FAccount := AAccount;
  FLock := TCriticalSection.Create;
  FIn := TStringList.Create;
  FOut := TStringList.Create;
end;

destructor TIRCConnection.Destroy;
begin
  FIn.Free;
  FOut.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TIRCConnection.Post(Kind: Char; const S: string);
begin
  FLock.Enter;
  try
    FIn.Add(Kind + S);
  finally
    FLock.Leave;
  end;
end;

function TIRCConnection.PopLine(out Kind: Char; out S: string): Boolean;
var
  T: string;
begin
  Kind := 'S';
  S := '';
  T := '';
  FLock.Enter;
  try
    Result := FIn.Count > 0;
    if Result then
    begin
      T := FIn[0];
      FIn.Delete(0);
    end;
  finally
    FLock.Leave;
  end;
  if Result then
  begin
    Kind := T[1];
    S := Copy(T, 2, MaxInt);
  end;
end;

function TIRCConnection.PopOut(out S: string): Boolean;
begin
  S := '';
  FLock.Enter;
  try
    Result := FOut.Count > 0;
    if Result then
    begin
      S := FOut[0];
      FOut.Delete(0);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TIRCConnection.Send(const ALine: string);
var
  S: string;
begin
  // never allow embedded CR/LF (command injection)
  S := StringReplace(ALine, #13, ' ', [rfReplaceAll]);
  S := StringReplace(S, #10, ' ', [rfReplaceAll]);
  FLock.Enter;
  try
    FOut.Add(S);
  finally
    FLock.Leave;
  end;
end;

procedure TIRCConnection.RequestQuit(const AMsg: string);
begin
  Send('QUIT :' + AMsg);
  FQuit := True;
end;

procedure TIRCConnection.WriteLine(ASock: TInetSocket; const S: string);
var
  T: string;
begin
  T := S + #13#10;
  ASock.WriteBuffer(T[1], Length(T));
end;

{ SASL PLAIN handshake. Registration is held back (by CAP REQ) until we send CAP END. }
procedure TIRCConnection.HandleSasl(ASock: TInetSocket; const ALine: string);
var
  M: TIRCMessage;
  Payload: string;
begin
  M := ParseIRCLine(ALine);
  if M.Command = 'CAP' then
  begin
    if (Length(M.Params) >= 3) and (M.Params[1] = 'ACK') and (Pos('sasl', M.Params[2]) > 0) then
      WriteLine(ASock, 'AUTHENTICATE PLAIN')
    else if (Length(M.Params) >= 2) and (M.Params[1] = 'NAK') then
    begin
      Post('S', 'Server does not support SASL; continuing without it.');
      FSaslBusy := False;
      WriteLine(ASock, 'CAP END');
    end;
  end
  else if (M.Command = 'AUTHENTICATE') and (Length(M.Params) > 0) and (M.Params[0] = '+') then
  begin
    Payload := EncodeStringBase64(FAccount + #0 + FAccount + #0 + FPassword);
    while Length(Payload) >= 400 do      // AUTHENTICATE data is sent in 400-byte chunks
    begin
      WriteLine(ASock, 'AUTHENTICATE ' + Copy(Payload, 1, 400));
      Delete(Payload, 1, 400);
    end;
    if Payload = '' then
      WriteLine(ASock, 'AUTHENTICATE +')
    else
      WriteLine(ASock, 'AUTHENTICATE ' + Payload);
  end
  else if M.Command = '903' then          // SASL success
  begin
    FSaslBusy := False;
    WriteLine(ASock, 'CAP END');
  end
  else if (M.Command = '902') or (M.Command = '904') or (M.Command = '905') or
          (M.Command = '906') or (M.Command = '907') then
  begin
    Post('S', 'SASL authentication failed - check the account name and password.');
    FSaslBusy := False;
    WriteLine(ASock, 'CAP END');
  end;
end;

procedure TIRCConnection.Execute;
var
  Sock: TInetSocket;
  H: TSocketHandler;
  Buf: array[0..4095] of Byte;
  Acc, Chunk, Line, S: string;
  N, P: Integer;
  T0: QWord;
begin
  Sock := nil;
  FillChar(Buf, SizeOf(Buf), 0);
  Acc := '';
  try
    try
      Post('S', Format('Connecting to %s:%d ...', [FHost, FPort]));
      if FUseSSL then
      begin
        H := TSSLSocketHandler.GetDefaultHandler;
        // TODO: load a CA bundle and turn verification on
        TSSLSocketHandler(H).VerifyPeerCert := False;
        Sock := TInetSocket.Create(FHost, FPort, H);
      end
      else
        Sock := TInetSocket.Create(FHost, FPort);
      Sock.Connect;
      Sock.IOTimeout := 100;   // ms; makes Read return/raise periodically so we can flush the send queue
      Post('S', 'Connected.');

      // SASL PLAIN when an account is set; otherwise a plain server password (PASS)
      FSaslBusy := (FAccount <> '') and (FPassword <> '');
      if FSaslBusy then
        WriteLine(Sock, 'CAP REQ :sasl')
      else if FPassword <> '' then
        WriteLine(Sock, 'PASS ' + FPassword);
      WriteLine(Sock, 'NICK ' + FNick);
      WriteLine(Sock, 'USER ' + FUser + ' 0 * :' + FRealName);

      while not Terminated do
      begin
        while PopOut(S) do
          WriteLine(Sock, S);
        if FQuit then
        begin
          while PopOut(S) do WriteLine(Sock, S);
          Break;
        end;

        T0 := GetTickCount64;
        try
          N := Sock.Read(Buf, SizeOf(Buf));
        except
          on Exception do
          begin
            // A timeout surfaces as an exception after ~IOTimeout ms; a real
            // error (reset, SSL failure) fails immediately, so re-raise that.
            if GetTickCount64 - T0 >= 50 then
              N := -1
            else
              raise;
          end;
        end;
        if N <= 0 then
        begin
          // A read that returns 0/-1 only after ~IOTimeout ms is just a timeout
          // (TLS reports it this way). Returning at once means the peer closed.
          if GetTickCount64 - T0 >= 50 then
            N := -1
          else
          begin
            Post('S', Format('Connection closed (read returned %d after %d ms).',
              [N, Integer(GetTickCount64 - T0)]));
            Break;
          end;
        end;
        if N > 0 then
        begin
          SetString(Chunk, PAnsiChar(@Buf[0]), N);
          Acc := Acc + Chunk;
          P := Pos(#10, Acc);
          while P > 0 do
          begin
            Line := Copy(Acc, 1, P - 1);
            Delete(Acc, 1, P);
            if (Line <> '') and (Line[Length(Line)] = #13) then
              SetLength(Line, Length(Line) - 1);
            if Line <> '' then
            begin
              if Copy(Line, 1, 5) = 'PING ' then
                WriteLine(Sock, 'PONG ' + Copy(Line, 6, MaxInt))
              else
              begin
                if FSaslBusy then HandleSasl(Sock, Line);
                Post('L', Line);
              end;
            end;
            P := Pos(#10, Acc);
          end;
        end;
      end;
    except
      on E: Exception do
        Post('S', 'Error: ' + E.Message);
    end;
  finally
    Sock.Free;
    FDone := True;
  end;
end;

end.
