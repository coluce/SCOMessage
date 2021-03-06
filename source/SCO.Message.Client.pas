unit SCO.Message.Client;

interface

uses
  System.SysUtils,
  System.Classes,
  System.UITypes,
  IPPeerClient,
  SCO.Message.Base,
  SCO.Message.Interfaces,
  Data.SqlExpr,
  System.Generics.Collections;

type

  TSCOClientProcessThread = class;
  TSCOMessageClient = class;

  { TSCOListenerSendThread }
  TSCOListenerSendThread = class(TThread)
  private
    { Private declarations }
    FException: Exception;
    FListener: ISCOMessageListener;
    FMessage: IMessage;
    procedure DoHandleException;
  protected
    { Protected declarations }
    procedure Execute; override;
    procedure HandleException; virtual;
  public
    { Public declarations }
    constructor Create(const AListener : ISCOMessageListener; const AMensagem: IMessage); reintroduce;
  end;

  TSCOClientProcessThread = class(TThread)
  private
    FMessageClient: TSCOMessageClient;
    procedure MsgStatus(AMessageClient : TSCOMessageClient; AMessage: IMessage);
  protected
    procedure Execute; override;
  public
    { Public declarations }
    constructor Create(AClienteMensageria : TSCOMessageClient); reintroduce;
    destructor  Destroy; override;
  end;

  TSCOMessageClient = class(TSCOMessageCommon)
  private
    FMensagemProcessamento : TSCOClientProcessThread;
    FListeners             : TList<ISCOMessageListener>;
    procedure DestruirThreadMonitora;
    procedure CriarThreadMonitora;
    { Private declarations }
  protected
    { Protected declarations }
    procedure SendToServer(AMensagem: IMessage); override;
    procedure DoAfterConectar; override;
    procedure DoAfterDesconectar; override;
  public
    { Public declarations }
    constructor Create(AOwner : TComponent); override;
    destructor  Destroy; override;
    procedure   SendMessage(AMensagem: IMessage); override;

    procedure   IsTheUserOnline(AUserName: string);
    procedure   RequestActiveUsers;
    procedure   RegisterListener(const AListener: ISCOMessageListener);
    procedure   UnregisterListener(const AListener: ISCOMessageListener);

    procedure   Open; override;
    procedure   Close; override;
  end;

implementation

{ TMensageriaCliente }

procedure TSCOMessageClient.Close;
begin
  Self.IsRemoteConnected := False;
end;

procedure TSCOMessageClient.CriarThreadMonitora;
begin
  DestruirThreadMonitora;
  FMensagemProcessamento := TSCOClientProcessThread.Create(Self);
end;

constructor TSCOMessageClient.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FListeners := TList<ISCOMessageListener>.Create;
end;

destructor TSCOMessageClient.Destroy;
begin
  DestruirThreadMonitora;
  FListeners.DisposeOf;
  FListeners := nil;
  inherited;
end;

procedure TSCOMessageClient.Open;
begin
  Self.IsRemoteConnected := True;
end;

procedure TSCOMessageClient.RegisterListener(const AListener: ISCOMessageListener);
begin
  if not FListeners.Contains(AListener) then
  begin
    FListeners.Add(AListener);
    FListeners.TrimExcess;
  end;
end;

procedure TSCOMessageClient.RequestActiveUsers;
var
  vMsg: IMessage;
begin
  vMsg := TMessageFactory.New;
  vMsg.Destiny := 'servidor';
  vMsg.Params.Add('usuarios.online',EmptyStr);
  SendMessage(vMsg);
end;

procedure TSCOMessageClient.SendToServer(AMensagem: IMessage);
begin
  try
    if AMensagem.UserName.Trim.IsEmpty then
    begin
      AMensagem.UserName := Self.UserName;
    end;
    {Subir a mensagem}
    Server.QueueMessage(AMensagem.ToText);
  except
  end;
end;

procedure TSCOMessageClient.UnregisterListener(const AListener: ISCOMessageListener);
begin
  if FListeners.Contains(AListener) then
  begin
    FListeners.Remove(AListener);
    FListeners.TrimExcess;
  end;
end;

procedure TSCOMessageClient.IsTheUserOnline(AUserName: string);
var
  vMsg: IMessage;
begin
  vMsg := TMessageFactory.New;
  vMsg.Destiny := AUserName;
  vMsg.Params.Add('status.verificacao',EmptyStr);
  SendMessage(vMsg);
end;

procedure TSCOMessageClient.DestruirThreadMonitora;
begin
  if Assigned(FMensagemProcessamento) then
  begin
    if FMensagemProcessamento.Started then
    begin
      FMensagemProcessamento.Terminate;
      if not FMensagemProcessamento.Suspended then
      begin
        FMensagemProcessamento.WaitFor;
      end;
    end;
    FMensagemProcessamento.DisposeOf;
    FMensagemProcessamento := nil;
  end;
end;

procedure TSCOMessageClient.DoAfterConectar;
begin
  inherited;
  CriarThreadMonitora;
end;

procedure TSCOMessageClient.DoAfterDesconectar;
begin
  inherited;
  DestruirThreadMonitora;
end;

procedure TSCOMessageClient.SendMessage(AMensagem: IMessage);
begin
  Self.SendToServer(AMensagem);
end;

{ TMensagemProcessamentoCliente }

constructor TSCOClientProcessThread.Create(
  AClienteMensageria: TSCOMessageClient);
begin
  inherited Create(False);
  FMessageClient := AClienteMensageria;
end;

destructor TSCOClientProcessThread.Destroy;
begin
  inherited;
end;

procedure TSCOClientProcessThread.Execute;
var
  vMsg : IMessage;
  vListener : ISCOMessageListener;
begin
  inherited;
  while not Self.Terminated do
  begin
    try
      if Self.Terminated then Exit;
      if not FMessageClient.MessageDequeue(vMsg) then
      begin
        if Self.Terminated then Exit;
        // caso n�o tenha mensagem na pilha, consome 100% do processamento
        // pois estamos em um while infinito
        Sleep(50);
        if Self.Terminated then Exit;
      end
      else
      begin
        if Self.Terminated then Exit;

        // Mensagens de status
        MsgStatus(FMessageClient,vMsg);

        if Self.Terminated then Exit;

        FMessageClient.MsgEntregar(vMsg);

        if Self.Terminated then Exit;

        //Varro os listeners registrados
        for vListener in FMessageClient.FListeners do
        begin
          //Crio thread passando o listener e a mensagem
            //Crio uma thread para que eu possa estourar excess�es dentro dos listeners
            //Se programar aqui direto, sem criar thread, a excess�o gerada pelo listener � "ocultada" pelo except deste procedimento
          TSCOListenerSendThread.Create(vListener, vMsg);
        end;
        Sleep(100);
      end;
    except on E: Exception do

    end;
  end;
end;

procedure TSCOClientProcessThread.MsgStatus(AMessageClient: TSCOMessageClient; AMessage: IMessage);
begin
  if AMessage.Params.ContainsKey('status.verificacao') then
  begin
    if AMessage.Destiny = AMessageClient.UserName then
    begin
      AMessageClient.SendStatusOnline(AMessage.UserName);
    end;
  end;
end;

{ TSCOListenerSendThread }

constructor TSCOListenerSendThread.Create(const AListener: ISCOMessageListener; const AMensagem: IMessage);
begin
  inherited Create(False);
  FreeOnTerminate := True;
  FListener := AListener;
  FMessage := AMensagem;
  FException := nil;
end;

procedure TSCOListenerSendThread.DoHandleException;
begin
  if Assigned(FException) then
  begin
    // Entregar pra main thread
    //MessageDlg(FException.Message, System.UITypes.TMsgDlgType.mtError, [System.UITypes.TMsgDlgBtn.mbok], 0);
  end;
end;

procedure TSCOListenerSendThread.Execute;
begin
  if Assigned(FListener) then
  begin
    try
      Synchronize(
        Self,
        procedure
        begin
          FListener.DoReceiveMessage(nil, FMessage);
        end
      );
    except
      HandleException;
    end;
  end;
end;

procedure TSCOListenerSendThread.HandleException;
begin
  FException := Exception(ExceptObject);
  try
    if Assigned(FException) then
    begin
      //N�o trato excess�es do tipo 'Abort'
      if not (FException is EAbort) then
      begin
        Synchronize(DoHandleException);
      end;
    end;
  finally
    FException := nil;
  end;
end;


end.


