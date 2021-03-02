unit ZapMQ.Wrapper;

interface

uses
  ZapMQ.Core, ZapMQ.Thread, ZapMQ.Handler, JSON, Generics.Collections,
  System.Classes, ZapMQ.Message.RPC, ZapMQ.Queue;

type
  TZapMQWrapper = class
  private
    FCore : TZapMQ;
    FListThreads : TObjectList<TZapMQThread>;
    FRPCThread : TZapMQRPCThread;
    FRPCMessages : TObjectList<TZapRPCMessage>;
    FOnRPCExpired: TEventRPCExpired;
    procedure SetOnRPCExpired(const Value: TEventRPCExpired);
    procedure CheckPriorityThreadAndCreate(const pPriority : TZapMQQueuePriority);
    procedure CheckPriorityThreadAndFree(const pPriority : TZapMQQueuePriority);
  public
    property OnRPCExpired : TEventRPCExpired read FOnRPCExpired write SetOnRPCExpired;
    function SendMessage(const pQueueName : string; const pMessage : TJSONObject;
      const pTTL : Word = 0) : boolean;
    function SendRPCMessage(const pQueueName : string; const pMessage : TJSONObject;
      const pHandler : TZapMQHandlerRPC; const pTTL : Word = 0) : boolean;
    procedure Bind(const pQueueName : string; const pHandler : TZapMQHanlder;
      const pPriority : TZapMQQueuePriority = mqpMedium);
    procedure UnBind(const pQueueName : string);
    function IsBinded(const pQueueName : string) : boolean;
    constructor Create(const pHost : string; const pPort : integer); overload;
    destructor Destroy; override;
  end;

implementation

uses
  ZapMQ.Message.JSON, System.SysUtils;

{ TZapMQWrapper }

procedure TZapMQWrapper.Bind(const pQueueName: string;
  const pHandler: TZapMQHanlder; const pPriority : TZapMQQueuePriority = mqpMedium);
var
  Queue : TZapMQQueue;
begin
  if pQueueName <> string.Empty then
  begin
    if not IsBinded(pQueueName) then
    begin
      Queue := TZapMQQueue.Create;
      Queue.Name := pQueueName;
      Queue.Handler := pHandler;
      Queue.Priority := pPriority;
      FCore.Queues.Add(Queue);
      CheckPriorityThreadAndCreate(pPriority);
    end;
  end
  else
    raise Exception.Create('You cannot bind an unnamed Queue');
end;

procedure TZapMQWrapper.CheckPriorityThreadAndCreate(
  const pPriority: TZapMQQueuePriority);
var
  ThreadAlreadyRunnig : boolean;
  Thread: TZapMQThread;
  NewThread : TZapMQThread;
begin
  ThreadAlreadyRunnig := False;
  for Thread in FListThreads do
  begin
    if Thread.QueuePriority = pPriority then
    begin
      ThreadAlreadyRunnig := True;
      Break;
    end;
  end;
  if not ThreadAlreadyRunnig then
  begin
    NewThread := TZapMQThread.Create(FCore, pPriority);
    FListThreads.Add(NewThread);
    NewThread.Start;
  end;
end;

procedure TZapMQWrapper.CheckPriorityThreadAndFree(
  const pPriority: TZapMQQueuePriority);
var
  Queue: TZapMQQueue;
  ThreadStilRunnig : boolean;
  Thread: TZapMQThread;
begin
  ThreadStilRunnig := False;
  for Queue in FCore.Queues do
  begin
    if Queue.Priority = pPriority then
    begin
      ThreadStilRunnig := True;
      Break;
    end;
  end;
  if not ThreadStilRunnig then
  begin
    for Thread in FListThreads do
    begin
      if Thread.QueuePriority = pPriority then
      begin
        Thread.Stop;
        FListThreads.Remove(Thread);
        Break;
      end;
    end;
  end;
end;

constructor TZapMQWrapper.Create(const pHost: string; const pPort: integer);
begin
  FCore := TZapMQ.Create(pHost, pPort);
  FRPCMessages := TObjectList<TZapRPCMessage>.Create(True);
  FListThreads := TObjectList<TZapMQThread>.Create(True);
  FRPCThread := TZapMQRPCThread.Create(pHost, pPort, FRPCMessages);
  FRPCThread.Start;
end;

destructor TZapMQWrapper.Destroy;
var
  Thread: TZapMQThread;
begin
  FRPCThread.Stop;
  FRPCThread.Free;
  for Thread in FListThreads do
  begin
    Thread.Stop;
  end;
  FListThreads.Clear;
  FListThreads.Free;
  FRPCMessages.Free;
  FCore.Free;
  inherited;
end;

function TZapMQWrapper.IsBinded(const pQueueName: string): boolean;
var
  Queue : TZapMQQueue;
begin
  Result := False;
  for Queue in FCore.Queues do
  begin
    if Queue.Name = pQueueName then
    begin
      Result := True;
      Break;
    end;
  end;
end;

function TZapMQWrapper.SendMessage(const pQueueName: string;
  const pMessage: TJSONObject; const pTTL: Word): boolean;
var
  ZapMessage : TZapJSONMessage;
begin
  if pQueueName = string.Empty then
    raise Exception.Create('Inform the Queue name');
  if not IsBinded(pQueueName) then
  begin
    ZapMessage := TZapJSONMessage.Create;
    try
      ZapMessage.Body := TJSONObject.ParseJSONValue(
        TEncoding.ASCII.GetBytes(pMessage.ToString), 0) as TJSONObject;
      ZapMessage.RPC := False;
      ZapMessage.TTL := pTTL;
      try
        FCore.SendMessage(pQueueName, ZapMessage);
        Result := True;
      except
        Result := False;
      end;
    finally
      ZapMessage.Free;
    end;
  end
  else
    raise Exception.Create('You cannot send message to a Queue self binded');
end;

function TZapMQWrapper.SendRPCMessage(const pQueueName : string; const pMessage : TJSONObject;
  const pHandler : TZapMQHandlerRPC; const pTTL : Word = 0) : boolean;
var
  JSONMessage : TZapJSONMessage;
  ZapRPCMessage : TZapRPCMessage;
begin
  if pQueueName = string.Empty then
    raise Exception.Create('Inform the Queue name');
  if not IsBinded(pQueueName) then
  begin
    JSONMessage := TZapJSONMessage.Create;
    JSONMessage.Body := TJSONObject.ParseJSONValue(
      TEncoding.ASCII.GetBytes(pMessage.ToString), 0) as TJSONObject;
    JSONMessage.RPC := True;
    JSONMessage.TTL := pTTL;
    try
      JSONMessage.Id := FCore.SendMessage(pQueueName, JSONMessage);
      if JSONMessage.Id <> string.Empty then
      begin
        FRPCThread.EventRPCExpired := FOnRPCExpired;
        ZapRPCMessage := TZapRPCMessage.Create(JSONMessage, pHandler, pQueueName);
        FRPCMessages.Add(ZapRPCMessage);
        FRPCThread.SyncEvent.SetEvent;
        Result := True;
      end
      else
      begin
        JSONMessage.Free;
        Result := False;
      end;
    except
      JSONMessage.Free;
      Result := False;
    end;
  end
  else
    raise Exception.Create('You cannot send message to a Queue self binded');
end;

procedure TZapMQWrapper.SetOnRPCExpired(const Value: TEventRPCExpired);
begin
  FOnRPCExpired := Value;
end;

procedure TZapMQWrapper.UnBind(const pQueueName: string);
var
  Queue : TZapMQQueue;
begin
  Queue := FCore.FindQueue(pQueueName);
  if Assigned(Queue) then
  begin
    FCore.Queues.Remove(Queue);
    CheckPriorityThreadAndFree(Queue.Priority);
  end;
end;

end.
