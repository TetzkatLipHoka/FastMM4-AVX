{
Fast Memory Manager: FullDebugMode Support DLL 1.71

Description:
 Support DLL for FastMM. With this DLL available, FastMM will report debug info (unit name, line numbers, etc.) for
 stack traces.

Usage:
 1) To compile you will need the JCL library (http://sourceforge.net/projects/jcl/)
 2) Place in the same location as the replacement borlndmm.dll or your application's executable module.

Change log:
 Version 1.00 (9 July 2005):
  - Initial release.
 Version 1.01 (13 July 2005):
  - Added the option to use madExcept instead of the JCL Debug library. (Thanks to Martin Aignesberger.)
 Version 1.02 (30 September 2005):
  - Changed options to display detail for addresses inside libraries as well.
 Version 1.03 (13 October 2005):
  - Added a raw stack trace procedure that implements raw stack traces.
 Version 1.10 (14 October 2005):
  - Improved the program logic behind the skipping of stack levels to cause less incorrect entries in raw stack traces.
    (Thanks to Craig Peterson.)
 Version 1.20 (17 October 2005):
  - Improved support for madExcept stack traces. (Thanks to Mathias Rauen.)
 Version 1.30 (26 October 2005):
  - Changed name to FastMM_FullDebugMode to reflect the fact that there is now a static dependency on this DLL for
    FullDebugMode.  The static dependency solves a DLL unload order issue.  (Thanks to Bart van der Werf.)
 Version 1.40 (31 October 2005):
  - Added support for EurekaLog. (Thanks to Fabio Dell'Aria.)
 Version 1.42 (23 June 2006):
  - Fixed a bug in the RawStackTraces code that may have caused an A/V in some rare circumstances. (Thanks to Primoz
    Gabrijelcic.)
 Version 1.44 (16 November 2006):
  - Changed the RawStackTraces code to prevent it from modifying the Windows "GetLastError" error code. (Thanks to
    Primoz Gabrijelcic.)
 Version 1.50 (14 August 2008):
  - Added support for Delphi 2009. (Thanks to Mark Edington.)
 Version 1.60 (5 May 2009):
  - Improved the code used to identify call instructions in the stack trace code.  (Thanks to the JCL team.)
 Version 1.61 (5 September 2010):
  - Recompiled using the latest JCL in order to fix a possible crash on shutdown when the executable contains no debug
    information. (Thanks to Hanspeter Widmer.)
 Version 1.62 (19 July 2012):
  - Added a workaround for QC 107209 (Thanks to David Heffernan.)
 Version 1.63 (14 September 2013):
  - Added support for OSX (Thanks to Sebastian Zierer)
 Version 1.64 (27 February 2021)
  - Implemented a return address information cache that greatly speeds up the conversion of many similar stack traces
    to text.
 Version 1.65 (10 July 2023)
  - Made LogStackTrace thread safe.
 Version 1.70 (19 July 2025)
  - Invalidate the memory map cache when a library is loaded or unloaded.
 Version 1.71 (29 April 2026)
  - Reduce the number of false positives in the 64-bit stack tracing code by skipping opcodes that are only valid in
    32-bit mode.

}

{$IFDEF MSWINDOWS}
{--------------------Start of options block-------------------------}

{Select the stack tracing library to use. The JCL, madExcept and EurekaLog are supported. Only one can be used at a
time.}
{$define JCLDebug}
{.$define madExcept}
{.$define EurekaLog_Legacy}
{.$define EurekaLog_V7}

{--------------------End of options block-------------------------}
{$ENDIF}

// JCL_DEBUG_EXPERT_INSERTJDBG OFF
library FastMM_FullDebugMode;

uses
  {$ifdef JCLDebug}JCLDebug,{$endif}
  {$ifdef madExcept}madStackTrace,{$endif}
  {$ifdef EurekaLog_Legacy}ExceptionLog,{$endif}
  {$ifdef EurekaLog_V7}EFastMM4Support,{$endif}
  SysUtils, {$IFDEF MACOS}Posix.Base, SBMapFiles{$ELSE}Windows{$ENDIF};

{$R *.res}

{$StackFrames on}
{$Warn Symbol_Platform off}
{$Align 8}

{The name of the 64-bit DLL has a '64' at the end.}
{$if SizeOf(Pointer) = 8}
{$LIBSUFFIX '64'}
{$ifend}

{$IF CompilerVersion <= 20}
type
  NativeUInt = Cardinal;
  PNativeUInt = ^NativeUInt;
  NativeInt = Integer;
{$IFEND}

{--------------------------Return Address Info Cache --------------------------}
{$IFDEF JCLDebug}
const
  CReturnAddressCacheSize = 4096;
  {FastMM assumes a maximum of 256 characters per stack trace entry.  The address text and line break are in addition to
  the info text.}
  CMaxInfoTextLength = 224;

type
  {The info text is cached and handed out as Unicode.  Source paths may contain
  characters that the system ANSI code page cannot represent - a Japanese or
  Cyrillic directory on a Western system - and converting through AnsiString
  replaces those with question marks, permanently.  On a pre-Unicode compiler
  the JCL hands us an AnsiString to begin with, so nothing is gained there for
  mixed scripts;  the implicit conversion below still uses the ANSI code page
  rather than assuming Latin-1, which is what makes single script non-Western
  paths survive.}
{$IFDEF UNICODE}
  TInfoString = UnicodeString;
{$ELSE}
  TInfoString = WideString;
{$ENDIF}

  {Return address info cache:  Maintains the source information for up to CReturnAddressCacheSize return addresses in
  a binary search tree.}

  PReturnAddressInfo = ^TReturnAddressInfo;
  TReturnAddressInfo = record
    ParentEntry: PReturnAddressInfo;
    ChildEntries: array[0..1] of PReturnAddressInfo;
    ReturnAddress: NativeUInt;
    {Length in characters, not bytes.}
    InfoTextLength: Integer;
    InfoText: array[0..CMaxInfoTextLength - 1] of WideChar;
  end;

  TReturnAddressInfoCache = {$IFDEF UNICODE}record{$ELSE}object{$ENDIF}
    {Entry 0 is the root of the tree.}
    Entries: array[0..CReturnAddressCacheSize] of TReturnAddressInfo;
    NextNewEntryIndex: Integer;
    function AddEntry(AReturnAddress: NativeUInt; const AReturnAddressInfoText: TInfoString): PReturnAddressInfo;
    procedure DeleteEntry(AEntry: PReturnAddressInfo);
    function FindEntry(AReturnAddress: NativeUInt): PReturnAddressInfo;
  end;

function TReturnAddressInfoCache.AddEntry(AReturnAddress: NativeUInt; const AReturnAddressInfoText: TInfoString): PReturnAddressInfo;
var
  LParentItem, LChildItem: PReturnAddressInfo;
  LAddressBits: NativeUInt;
  LChildIndex: Integer;
begin
  {Get the address of the entry to reuse. (Entry 0 is the tree root.)}
  if NextNewEntryIndex = High(Entries) then
    NextNewEntryIndex := 0;
  Inc(NextNewEntryIndex);

  Result := @Entries[NextNewEntryIndex];

  {Delete it if it is already in use}
  DeleteEntry(Result);

  {Step down the tree until an open slot is found in the required direction.}
  LParentItem := @Entries[0];
  LAddressBits := AReturnAddress;
  while True do
  begin
    {Get the current child in the appropriate direction.}
    LChildItem := LParentItem.ChildEntries[LAddressBits and 1];
    {No child -> This slot is available.}
    if LChildItem = nil then
      Break;
    {Traverse further down the tree.}
    LParentItem := LChildItem;
    LAddressBits := LAddressBits shr 1;
  end;
  LChildIndex := LAddressBits and 1;

  {Insert the node into the tree}
  LParentItem.ChildEntries[LChildIndex] := Result;
  Result.ParentEntry := LParentItem;

  {Set the info text for the item.}
  Result.ReturnAddress := AReturnAddress;
  Result.InfoTextLength := Length(AReturnAddressInfoText);
  if Result.InfoTextLength > CMaxInfoTextLength then
    Result.InfoTextLength := CMaxInfoTextLength;
  System.Move(Pointer(AReturnAddressInfoText)^, Result.InfoText, Result.InfoTextLength * SizeOf(WideChar));
end;

procedure TReturnAddressInfoCache.DeleteEntry(AEntry: PReturnAddressInfo);
var
  LRemovedItemChildIndex, LMovedItemChildIndex: Integer;
  LMovedItem, LChildItem: PReturnAddressInfo;
begin
  {Is this entry currentlty in the tree?}
  if AEntry.ParentEntry = nil then
    Exit;

  LRemovedItemChildIndex := Ord(AEntry.ParentEntry.ChildEntries[1] = AEntry);

  {Does this item have children of its own?}
  if (NativeInt(AEntry.ChildEntries[0]) or NativeInt(AEntry.ChildEntries[1])) <> 0 then
  begin
    {It has children:  We need to traverse child items until we find a leaf item and then move it into this item's
    position in the search tree.}
    LMovedItem := AEntry;

    while True do
    begin
      LChildItem := LMovedItem.ChildEntries[0]; //try left then right
      if LChildItem = nil then
      begin
        LChildItem := LMovedItem.ChildEntries[1];
        if LChildItem = nil then
          Break;
      end;
      LMovedItem := LChildItem;
    end;

    {Disconnect the moved item from its current parent item.}
    LMovedItemChildIndex := Ord(LMovedItem.ParentEntry.ChildEntries[1] = LMovedItem);
    LMovedItem.ParentEntry.ChildEntries[LMovedItemChildIndex] := nil;

    {Set the new parent for the moved item}
    AEntry.ParentEntry.ChildEntries[LRemovedItemChildIndex] := LMovedItem;
    LMovedItem.ParentEntry := AEntry.ParentEntry;

    {Set the new left child for the moved item}
    LChildItem := AEntry.ChildEntries[0];
    if LChildItem <> nil then
    begin
      LMovedItem.ChildEntries[0] := LChildItem;
      LChildItem.ParentEntry := LMovedItem;
      AEntry.ChildEntries[0] := nil;
    end;

    {Set the new right child for the moved item}
    LChildItem := AEntry.ChildEntries[1];
    if LChildItem <> nil then
    begin
      LMovedItem.ChildEntries[1] := LChildItem;
      LChildItem.ParentEntry := LMovedItem;
      AEntry.ChildEntries[1] := nil;
    end;

  end
  else
  begin
    {The deleted item is a leaf item:  Remove it from the tree directly.}
    AEntry.ParentEntry.ChildEntries[LRemovedItemChildIndex] := nil;
  end;
  {Reset the parent for the removed item.}
  AEntry.ParentEntry := nil;
end;

function TReturnAddressInfoCache.FindEntry(AReturnAddress: NativeUInt): PReturnAddressInfo;
var
  LAddressBits: NativeUInt;
  LParentItem: PReturnAddressInfo;
begin
  LAddressBits := AReturnAddress;
  LParentItem := @Entries[0];
  {Step down the tree until the item is found or there is no child item in the required direction.}
  while True do
  begin
    {Get the child item in the required direction.}
    Result := LParentItem.ChildEntries[LAddressBits and 1];
    {If there is no child, or the child's key value matches the search key value then we're done.}
    if (Result = nil)
      or (Result.ReturnAddress = AReturnAddress) then
    begin
      Exit;
    end;
    {The child key value is not a match -> Move down the tree.}
    LParentItem := Result;
    LAddressBits := LAddressBits shr 1;
  end;
end;
{$ENDIF JCLDebug}

{--------------------------Stack Tracing Subroutines--------------------------}

procedure GetStackRange(var AStackBaseAddress, ACurrentStackPointer: NativeUInt);
asm
  {$if SizeOf(Pointer) = 8}
  mov rax, gs:[abs 8]
  mov [rcx], rax
  mov [rdx], rbp
  {$else}
  mov ecx, fs:[4]
  mov [eax], ecx
  mov [edx], ebp
  {$ifend}
end;

{--------------------------Frame Based Stack Tracing--------------------------}

{$if SizeOf(Pointer) = 8}

function CaptureStackBackTrace(FramesToSkip, FramesToCapture: DWORD; BackTrace: Pointer; BackTraceHash: PDWORD): Word;
  external kernel32 name 'RtlCaptureStackBackTrace';

{We use the Windows API to do frame based stack tracing under 64-bit.}
procedure GetFrameBasedStackTrace(AReturnAddresses: PNativeUInt; AMaxDepth, ASkipFrames: Cardinal);
type
{$PointerMath On}
  PNativeUIntArray = ^NativeUInt;
{$PointerMath Off}
var
  LCapturedFrameCount: Cardinal;
begin
  LCapturedFrameCount := CaptureStackBackTrace(ASkipFrames, AMaxDepth, AReturnAddresses, nil);

  {Clear trailing entries}
  while LCapturedFrameCount < AMaxDepth do
  begin
    PNativeUIntArray(AReturnAddresses)[LCapturedFrameCount] := 0;
    Inc(LCapturedFrameCount);
  end;
end;

{$else}

{Dumps the call stack trace to the given address. Fills the list with the addresses where the called addresses can be
found.  This is the fast stack frame based tracing routine.}
procedure GetFrameBasedStackTrace(AReturnAddresses: PNativeUInt; AMaxDepth, ASkipFrames: Cardinal);
var
  LStackTop, LStackBottom, LCurrentFrame: NativeUInt;
begin
  {Get the call stack top and current bottom}
  GetStackRange(LStackTop, LStackBottom);
  Dec(LStackTop, SizeOf(Pointer) - 1);
  {Get the current frame start}
  LCurrentFrame := LStackBottom;
  {Fill the call stack}
  while (AMaxDepth > 0)
    and (LCurrentFrame >= LStackBottom)
    and (LCurrentFrame < LStackTop) do
  begin
    {Ignore the requested number of levels}
    if ASkipFrames = 0 then
    begin
      AReturnAddresses^ := PNativeUInt(LCurrentFrame + SizeOf(Pointer))^;
      Inc(AReturnAddresses);
      Dec(AMaxDepth);
    end
    else
      Dec(ASkipFrames);
    {Get the next frame}
    LCurrentFrame := PNativeUInt(LCurrentFrame)^;
  end;
  {Clear the remaining entries}
  while AMaxDepth > 0 do
  begin
    AReturnAddresses^ := 0;
    Inc(AReturnAddresses);
    Dec(AMaxDepth);
  end;
end;
{$ifend}

{-----------------------------Raw Stack Tracing-----------------------------}

const
  {Hexadecimal characters}
  HexTable: array[0..15] of AnsiChar = '0123456789ABCDEF';

type
  {The state of a memory page. Used by the raw stack tracing mechanism to determine whether an address is a valid call
  site or not.}
  TMemoryPageAccess = (mpaUnknown, mpaNotExecutable, mpaExecutable);

var
  {There are a total of 1M x 4K pages in the (low) 4GB address space}
  MemoryPageAccessMap: array[0..1024 * 1024 - 1] of TMemoryPageAccess;

{$IFDEF MSWINDOWS}

procedure InvalidateMemoryPageAccessMap(ABaseAddress: Pointer; ASize: NativeUInt);
const
  CPageSize = 4096;
var
  LStartPage, LEndPage: NativeUInt;
  LPageCount: NativeInt;
begin
  if ASize = 0 then
    Exit;

  LStartPage := NativeUInt(ABaseAddress) div CPageSize;
  LEndPage := LStartPage + (ASize - 1) div CPageSize;
  if LEndPage > High(MemoryPageAccessMap) then
    LEndPage := High(MemoryPageAccessMap);

  LPageCount := LEndPage - LStartPage + 1;
  if LPageCount > 0 then
    FillChar(MemoryPageAccessMap[LStartPage], LPageCount, Ord(mpaUnknown));
end;

{Updates the memory page access map. Currently only supports the low 4GB of address space.}
procedure UpdateMemoryPageAccessMap(AAddress: NativeUInt);
var
  LMemInfo: TMemoryBasicInformation;
  LAccess: TMemoryPageAccess;
  LStartPage, LPageCount: NativeUInt;
begin
  {Query the page}
  if VirtualQuery(Pointer(AAddress), LMemInfo, SizeOf(LMemInfo)) <> 0 then
  begin
    {Get access type}
    if (LMemInfo.State = MEM_COMMIT)
      and (LMemInfo.Protect and (PAGE_EXECUTE_READ or PAGE_EXECUTE_READWRITE or PAGE_EXECUTE_WRITECOPY or PAGE_EXECUTE) <> 0)
      and (LMemInfo.Protect and PAGE_GUARD = 0) then
    begin
      LAccess := mpaExecutable
    end
    else
      LAccess := mpaNotExecutable;
    {Update the map}
    LStartPage := NativeUInt(LMemInfo.BaseAddress) div 4096;
    LPageCount := LMemInfo.RegionSize div 4096;
    if LStartPage < NativeUInt(Length(MemoryPageAccessMap)) then
    begin
      if (LStartPage + LPageCount) >= NativeUInt(Length(MemoryPageAccessMap)) then
        LPageCount := NativeUInt(Length(MemoryPageAccessMap)) - LStartPage;
      FillChar(MemoryPageAccessMap[LStartPage], LPageCount, Ord(LAccess));
    end;
  end
  else
  begin
    {Invalid address}
    MemoryPageAccessMap[AAddress div 4096] := mpaNotExecutable;
  end;
end;
{$ENDIF}

{Thread-safe version that avoids the global variable Default8087CW.}
procedure Set8087CW(ANewCW: Word);
var
  L8087CW: Word;
asm
  mov L8087CW, ANewCW
  fnclex
  fldcw L8087CW
end;

{$if CompilerVersion > 22}
{Thread-safe version that avoids the global variable DefaultMXCSR.}
procedure SetMXCSR(ANewMXCSR: Cardinal);
var
  LMXCSR: Cardinal;
asm
  {$if SizeOf(Pointer) <> 8}
  cmp System.TestSSE, 0
  je @exit
  {$ifend}
  {Remove the flag bits}
  and ANewMXCSR, $ffc0
  mov LMXCSR, ANewMXCSR
  ldmxcsr LMXCSR
@exit:
end;
{$ifend}

{$IFDEF MSWINDOWS}
{Returns true if the return address is a valid call site.  This function is only safe to call while exceptions are
being handled.}
{$IF NOT Declared( GetMXCSR )}
var
  TestSSE : Cardinal;
  DefaultMXCSR : Cardinal = $1900;

function GetMXCSR: Cardinal;
{$IF Defined( Win32 )}
asm
{$IFDEF PIC}
        XOR     EAX, EAX
        PUSH    EAX
        CALL    GetGOT
        MOV     EAX, [EAX].OFFSET TestSSE
        CMP     [EAX], 0
        POP     EAX
        JE      @@NOSSE
{$ELSE !PIC}
        XOR     EAX, EAX
        CMP     TestSSE, EAX
        JE      @@NOSSE
{$ENDIF !PIC}
        PUSH    EAX
        STMXCSR [ESP].DWord
        POP     EAX
@@NOSSE:
end;
{$ELSEIF defined( Win64 )}
asm
        PUSH    0
        STMXCSR [RSP].DWord
        POP     RAX
end;
{$ELSE}
{$MESSAGE ERROR 'Unknown platform'}
{$IFEND}
{$IFEND}

function IsValidCallSite(AReturnAddress: NativeUInt): Boolean;
  {$IF NOT Declared( SetMXCSR )}
  procedure SetMXCSR(NewMXCSR: Cardinal);
  {$IF defined(Win32)}
  begin
    if TestSSE = 0 then exit;
    DefaultMXCSR := NewMXCSR and $FFC0;  // Remove status flag bits
    asm
  {$IFDEF PIC}
          MOV     EAX,[EBX].OFFSET DefaultMXCSR
          LDMXCSR [EAX]
  {$ELSE !PIC}
          LDMXCSR DefaultMXCSR
  {$ENDIF !PIC}
    end;
  end;
  {$ELSEIF defined(Win64)}
  asm
          AND     ECX, $FFC0 // Remove flag bits
          MOV     DefaultMXCSR, ECX
          LDMXCSR DefaultMXCSR
  end;
  {$ELSE}
  {$MESSAGE ERROR 'Unknown platform'}
  {$IFEND}
  {$IFEND}
var
  LCallAddress: NativeUInt;
  LCode8Back, LCode4Back, LTemp: Cardinal;
  LOld8087CW: Word;
  LOldMXCSR: Cardinal;
begin
  {We assume (for now) that all application code will execute within the first 4GB of address space.}
  if (AReturnAddress > $ffff) {$if SizeOf(Pointer) = 8}and (AReturnAddress <= $ffffffff){$IFEND} then
  begin
    {The call address is up to 8 bytes before the return address}
    LCallAddress := AReturnAddress - 8;
    {Update the page map}
    if MemoryPageAccessMap[LCallAddress div 4096] = mpaUnknown then
      UpdateMemoryPageAccessMap(LCallAddress);
    {Check the page access}
    if (MemoryPageAccessMap[LCallAddress div 4096] = mpaExecutable)
      and (MemoryPageAccessMap[(LCallAddress + 8) div 4096] = mpaExecutable) then
    begin
      {Try to determine what kind of call it is (if any), more or less in order of frequency of occurrence. (Code below
      taken from the Jedi Code Library (jcl.sourceforge.net).)  We need to retrieve the current floating point control
      registers, since any external exception will reset it to the DLL defaults which may not otherwise correspond to
      the defaults of the main application (QC 107198).}
      LOld8087CW := Get8087CW;
      LOldMXCSR := GetMXCSR;
      try
        {5 bytes, CALL NEAR REL32}
        if PByteArray(LCallAddress)[3] = $E8 then
        begin
          Result := True;
          Exit;
        end;
        {Get the 4 bytes before the return address}
        LCode4Back := PCardinal(LCallAddress + 4)^;
        {2 byte call?}
        LTemp := LCode4Back and $F8FF0000;
        {2 bytes, CALL NEAR EAX}
        if LTemp = $D0FF0000 then
        begin
          Result := True;
          Exit;
        end;
        {2 bytes, CALL NEAR [EAX]}
        if LTemp = $10FF0000 then
        begin
          LTemp := LCode4Back - LTemp;
          if (LTemp <> $04000000) and (LTemp <> $05000000) then
          begin
            Result := True;
            Exit;
          end;
        end;
        {3 bytes, CALL NEAR [EAX+EAX*i]}
        if (LCode4Back and $00FFFF00) = $0014FF00 then
        begin
          Result := True;
          Exit;
        end;
        {3 bytes, CALL NEAR [EAX+$12]}
        if ((LCode4Back and $00F8FF00) = $0050FF00)
          and ((LCode4Back and $00070000) <> $00040000) then
        begin
          Result := True;
          Exit;
        end;
        {4 bytes, CALL NEAR [EAX+EAX+$12]}
        if Word(LCode4Back) = $54FF then
        begin
          Result := True;
          Exit;
        end;
        {6 bytes, CALL NEAR [$12345678]}
        LCode8Back := PCardinal(LCallAddress)^;
        if (LCode8Back and $FFFF0000) = $15FF0000 then
        begin
          Result := True;
          Exit;
        end;
        {6 bytes, CALL NEAR [EAX+$12345678]}
        if ((LCode8Back and $F8FF0000) = $90FF0000)
          and ((LCode8Back and $07000000) <> $04000000) then
        begin
          Result := True;
          Exit;
        end;
        {7 bytes, CALL NEAR [EAX+EAX+$1234567]}
        if (LCode8Back and $00FFFF00) = $0094FF00 then
        begin
          Result := True;
          Exit;
        end;
{$ifndef CPUX64} //The 9A cp opcode is not valid in 64-bit mode
        {7 bytes, CALL FAR $1234:12345678}
        if (LCode8Back and $0000FF00) = $00009A00 then
        begin
          Result := True;
          Exit;
        end;
{$endif}
        {Not a valid call site}
        Result := False;
      except
        {The access has changed}
        UpdateMemoryPageAccessMap(LCallAddress);
        {The RTL sets the FPU control words to the default values if an external exception occurs.  Reset their values
        here to the values on entry to this call.}
        Set8087CW(LOld8087CW);
        SetMXCSR(LOldMXCSR);
        {Not executable}
        Result := False;
      end;
    end
    else
      Result := False;
  end
  else
    Result := False;
end;
{$ENDIF}

{Dumps the call stack trace to the given address.  Fills the list with the addresses where the called addresses can be
found.  This is the "raw" stack tracing routine.}

{$IFDEF MACOS}
function backtrace(result: PNativeUInt; size: Integer): Integer; cdecl; external libc name '_backtrace';
function _NSGetExecutablePath(buf: PAnsiChar; BufSize: PCardinal): Integer; cdecl; external libc name '__NSGetExecutablePath';
{$ENDIF}

procedure GetRawStackTrace(AReturnAddresses: PNativeUInt; AMaxDepth, ASkipFrames: Cardinal);
var
  LStackTop, LStackBottom, LCurrentFrame, LNextFrame, LReturnAddress, LStackAddress: NativeUInt;
  LLastOSError: Cardinal;

{$IFDEF MACOS}
  StackLog: PNativeUInt; //array[0..10] of Pointer;
  Cnt: Integer;
  I: Integer;
{$ENDIF}
begin
  {$IFDEF MACOS}
  {$POINTERMATH ON}
  Cnt := AMaxDepth + ASkipFrames;

  GetMem(StackLog, SizeOf(Pointer) * Cnt);
  try
    Cnt := backtrace(StackLog, Cnt);

    for I := ASkipFrames to Cnt - 1 do
    begin
//      writeln('Stack: ', inttohex(NativeUInt(stacklog[I]), 8));
      AReturnAddresses[I - ASkipFrames] := StackLog[I];
    end;

  finally
    FreeMem(StackLog);
  end;
  {$POINTERMATH OFF}
  {$ENDIF}
  {Are exceptions being handled? Can only do a raw stack trace if the possible access violations are going to be
  handled.}
{$IFDEF MSWINDOWS}
  if Assigned(ExceptObjProc) then
  begin
    {Save the last Windows error code}
    LLastOSError := GetLastError;
    {Get the call stack top and current bottom}
    GetStackRange(LStackTop, LStackBottom);
    Dec(LStackTop, SizeOf(Pointer) - 1);
    {Get the current frame start}
    LCurrentFrame := LStackBottom;
    {Fill the call stack}
    while (AMaxDepth > 0)
      and (LCurrentFrame < LStackTop) do
    begin
      {Get the next frame}
      LNextFrame := PNativeUInt(LCurrentFrame)^;
      {Is it a valid stack frame address?}
      if (LNextFrame < LStackTop)
        and (LNextFrame > LCurrentFrame) then
      begin
        {The pointer to the next stack frame appears valid:  Get the return address of the current frame}
        LReturnAddress := PNativeUInt(LCurrentFrame + SizeOf(Pointer))^;
        {Does this appear to be a valid return address}
        if (LReturnAddress > $ffff) {$if SizeOf(Pointer) = 8}and (LReturnAddress <= $ffffffff){$IFEND} then
        begin
          {Is the map for this return address incorrect? It may be unknown or marked as non-executable because a library
          was previously not yet loaded, or perhaps this is not a valid stack frame.}
          if MemoryPageAccessMap[(LReturnAddress - 8) div 4096] <> mpaExecutable then
            UpdateMemoryPageAccessMap(LReturnAddress - 8);
          {Is this return address actually valid?}
          if IsValidCallSite(LReturnAddress) then
          begin
            {Ignore the requested number of levels}
            if ASkipFrames = 0 then
            begin
              AReturnAddresses^ := LReturnAddress;
              Inc(AReturnAddresses);
              Dec(AMaxDepth);
            end;
          end
          else
          begin
            {If the return address is invalid it implies this stack frame is invalid after all.}
            LNextFrame := LStackTop;
          end;
        end
        else
        begin
          {The return address is bad - this is not a valid stack frame}
          LNextFrame := LStackTop;
        end;
      end
      else
      begin
        {This is not a valid stack frame}
        LNextFrame := LStackTop;
      end;
      {Do not check intermediate entries if there are still frames to skip}
      if ASkipFrames <> 0 then
      begin
        Dec(ASkipFrames);
      end
      else
      begin
        {Check all stack entries up to the next stack frame}
        LStackAddress := LCurrentFrame + 2 * SizeOf(Pointer);
        while (AMaxDepth > 0)
          and (LStackAddress < LNextFrame) do
        begin
          {Get the return address}
          LReturnAddress := PNativeUInt(LStackAddress)^;
          {Is this a valid call site?}
          if IsValidCallSite(LReturnAddress) then
          begin
            AReturnAddresses^ := LReturnAddress;
            Inc(AReturnAddresses);
            Dec(AMaxDepth);
          end;
          {Check the next stack address}
          Inc(LStackAddress, SizeOf(Pointer));
        end;
      end;
      {Do the next stack frame}
      LCurrentFrame := LNextFrame;
    end;
    {Clear the remaining entries}
    while AMaxDepth > 0 do
    begin
      AReturnAddresses^ := 0;
      Inc(AReturnAddresses);
      Dec(AMaxDepth);
    end;
    {Restore the last Windows error code, since a VirtualQuery call may have modified it.}
    SetLastError(LLastOSError);
  end
  else
  begin
    {Exception handling is not available - do a frame based stack trace}
    GetFrameBasedStackTrace(AReturnAddresses, AMaxDepth, ASkipFrames);
  end;
  {$ENDIF}
end;

{--------------------------DLL load and unload notifications--------------------------}

{$IFDEF MSWINDOWS}

type

  UNICODE_STRING = record
    Length: Word;
    MaximumLength: Word;
    Buffer: PWideChar;
  end;
  PUNICODE_STRING = ^UNICODE_STRING;

  TCLDR_DLL_NOTIFICATION_DATA = record
    Flags: Cardinal;                //Reserved.
    FullDllName: PUNICODE_STRING;   //The full path name of the DLL module.
    BaseDllName: PUNICODE_STRING;   //The base file name of the DLL module.
    DllBase: Pointer;               //A pointer to the base address for the DLL in memory.
    SizeOfImage: Cardinal;          //The size of the DLL image, in bytes.
  end;
  PCLDR_DLL_NOTIFICATION_DATA = ^TCLDR_DLL_NOTIFICATION_DATA;

  TLdrDllNotification = procedure(NotificationReason: Cardinal; NotificationData: PCLDR_DLL_NOTIFICATION_DATA;
    Context: Pointer); stdcall;

  TLdrRegisterDllNotification = function(Flags: Cardinal; NotificationFunction: TLdrDllNotification;
    Context: Pointer; var Cookie: Pointer): LongInt; stdcall;

  TLdrUnregisterDllNotification = function(Cookie: Pointer): LongInt; stdcall;

procedure LdrDllNotification(NotificationReason: Cardinal; NotificationData: PCLDR_DLL_NOTIFICATION_DATA;
  Context: Pointer); stdcall;
begin
  InvalidateMemoryPageAccessMap(NotificationData.DllBase, NotificationData.SizeOfImage);
end;

var
  DllNotificationCookie: Pointer = nil;

procedure RegisterDLLLoadAndUnloadNotifications;
var
  LdrRegisterDllNotification: TLdrRegisterDllNotification;
begin
  if DllNotificationCookie <> nil then
    Exit;

  {Attempt to register notifications when a DLL is loaded or unloaded.}
  LdrRegisterDllNotification := GetProcAddress(GetModuleHandle('NTDLL.DLL'), 'LdrRegisterDllNotification');
  if Assigned(LdrRegisterDllNotification) then
  begin
    if LdrRegisterDllNotification(0, LdrDllNotification, nil, DllNotificationCookie) <> ERROR_SUCCESS then
      DllNotificationCookie := nil;
  end;

  if DllNotificationCookie = nil then
    OutputDebugString('FastMM_FullDebugMode: Failed to register DLL load and unload notifications.');
end;

procedure UnregisterDLLLoadAndUnloadNotifications;
var
  LdrUnregisterDllNotification: TLdrUnregisterDllNotification;
begin
  if DllNotificationCookie = nil then
    Exit;

  LdrUnregisterDllNotification := GetProcAddress(GetModuleHandle('NTDLL.DLL'), 'LdrUnregisterDllNotification');
  if Assigned(LdrUnregisterDllNotification)
    and (LdrUnregisterDllNotification(DllNotificationCookie) = ERROR_SUCCESS) then
  begin
    DllNotificationCookie := nil;
  end;

  if DllNotificationCookie <> nil then
    OutputDebugString('FastMM_FullDebugMode: Failed to deregister DLL load and unload notifications.');
end;

procedure DllMain(AReason: Integer);
begin
  if AReason = DLL_PROCESS_DETACH then
    UnregisterDLLLoadAndUnloadNotifications;
end;

{$ENDIF}

{------------------------------------------}
{--------Atomic calls for Delphi XE2-------}
{------------------------------------------}

{$IF RTLVersion < 24.00}

(*
function AtomicIncrement(var Target: Cardinal): Cardinal; overload;
asm
{$IFDEF CPUX64}
  // --> RCX Target
  // <-- EAX Result
  MOV     EAX, 1
  LOCK XADD [RCX], EAX
  INC     EAX
{$ELSE}
  // --> EAX Target
  // <-- EAX Result
  MOV     ECX, EAX
  MOV     EAX, 1
  LOCK XADD [ECX], EAX
  INC     EAX
{$ENDIF}
end;

function AtomicIncrement(var Target: Integer): Integer; overload;
asm
{$IFDEF CPUX64}
  // --> RCX Target
  // <-- EAX Result
  MOV     EAX, 1
  LOCK XADD [RCX], EAX
  INC     EAX
{$ELSE}
  // --> EAX Target
  // <-- EAX Result
  MOV     ECX, EAX
  MOV     EAX, 1
  LOCK XADD [ECX], EAX
  INC     EAX
{$ENDIF}
end;

function AtomicIncrement(var Target: NativeUInt; Value: NativeUInt): NativeUInt; overload;
asm
{$IFDEF CPUX64}
  // --> RCX Target
  //     RDX Value
  // <-- RAX Result
  MOV     RAX, RDX
  LOCK XADD [RCX], RAX
  ADD     RAX, RDX
{$ELSE}
  // --> EAX Target
  //     EDX Value
  // <-- EAX Result
  MOV     ECX, EAX
  MOV     EAX, EDX
  LOCK XADD [ECX], EAX
  ADD     EAX, EDX
{$ENDIF}
end;

function AtomicDecrement(var Target: Integer): Integer; overload;
asm
{$IFDEF CPUX64}
  // --> RCX Target
  // <-- EAX Result
  MOV     EAX, -1
  LOCK XADD [RCX], EAX
  DEC     EAX
{$ELSE}
  // --> EAX Target
  // <-- EAX Result
  MOV     ECX, EAX
  MOV     EAX, -1
  LOCK XADD [ECX], EAX
  DEC     EAX
{$ENDIF}
end;

function AtomicDecrement(var Target: NativeUInt; Value: NativeUInt): NativeUInt; overload;
asm
{$IFDEF CPUX64}
  // --> RCX Target
  //     RDX Value
  // <-- RAX Result
  NEG     RDX
  MOV     RAX, RDX
  LOCK XADD [RCX], RAX
  ADD     RAX, RDX
{$ELSE}
  // --> EAX Target
  //     EDX Value
  // <-- EAX Result
  MOV     ECX, EAX
  NEG     EDX
  MOV     EAX, EDX
  LOCK XADD [ECX], EAX
  ADD     EAX, EDX
{$ENDIF}
end;

function AtomicExchange(var Target: Integer; Value: Integer): Integer; overload;
asm
{$IFDEF CPUX64}
  // --> RCX Target
  //     EDX Value
  // <-- EAX Result
  MOV     EAX, EDX
  //     RCX Target
  //     EAX Value
  LOCK XCHG [RCX], EAX
{$ELSE}
  // --> EAX Target
  //     EDX Value
  // <-- EAX Result
  MOV     ECX, EAX
  MOV     EAX, EDX
  //     ECX Target
  //     EAX Value
  LOCK XCHG [ECX], EAX
{$ENDIF}
end;

function AtomicExchange(var Target: Pointer; Value: Pointer): Pointer; overload;
asm
{$IFDEF CPUX64}
  // --> RCX Target
  //     RDX Value
  // <-- RAX Result
  MOV     RAX, RDX
  LOCK XCHG [RCX], RAX
{$ELSE}
  // --> EAX Target
  //     EDX Value
  // <-- EAX Result
  MOV     ECX, EAX
  MOV     EAX, EDX
  //     ECX Target
  //     EAX Value
  LOCK XCHG [ECX], EAX
{$ENDIF}
end;
*)

function AtomicCmpExchange(var Target: Integer; Value: Integer; Compare: Integer): Integer; overload;
asm
{$IFDEF CPUX64}
  // --> RCX Target
  //     EDX Value
  //     R8  Compare
  // <-- EAX Result
  MOV     RAX, R8
  //     RCX Target
  //     EDX Value
  //     RAX Compare
  LOCK CMPXCHG [RCX], EDX
{$ELSE}
  // --> EAX Target
  //     EDX Value
  //     ECX Compare
  // <-- EAX Result
  XCHG    EAX, ECX
  //     EAX Compare
  //     EDX Value
  //     ECX Target
  LOCK CMPXCHG [ECX], EDX
{$ENDIF}
end;

function AtomicCmpExchange(var Target: Int64; Value: Int64; Compare: Int64): Int64; overload;
asm
{$IFDEF CPUX64}
  // --> RCX Target
  //     RDX Value
  //     R8  Compare
  // <-- RAX Result
  MOV     RAX, R8
  LOCK CMPXCHG [RCX], RDX
{$ELSE}
  PUSH EBX
  PUSH EDI
  MOV EDI, EAX  // Target
  MOV EAX, DWORD PTR [Compare]
  MOV EDX, DWORD PTR [Compare+4]
  MOV EBX, DWORD PTR [Value]
  MOV ECX, DWORD PTR [Value+4]
  LOCK CMPXCHG8B QWORD PTR [EDI]
  POP EDI
  POP EBX
{$ENDIF}
end;

function AtomicCmpExchange(var Target: Pointer; Value: Pointer; Compare: Pointer): Pointer; overload;
asm
{$IFDEF CPUX64}
  // --> RCX Target
  //     RDX Value
  //     R8  Compare
  // <-- RAX Result
  MOV     RAX, R8
  //     RCX Target
  //     RDX Value
  //     RAX Compare
  LOCK CMPXCHG [RCX], RDX
{$ELSE}
  // --> EAX Target
  //     EDX Value
  //     ECX Compare
  // <-- EAX Result
  XCHG    EAX, ECX
  //     EAX Comp
  //     EDX Value
  //     ECX Target
  LOCK CMPXCHG [ECX], EDX
{$ENDIF}
end;

{$IFEND}

{-----------------------------Stack Trace Logging----------------------------}

{Gets the textual representation of the stack trace into ABuffer and returns a pointer to the position just after the
last character.}
{$ifdef JCLDebug}
{Converts an unsigned integer to a hexadecimal string at the buffer location, returning the new buffer position.}
function NativeUIntToHexBuf(ANum: NativeUInt; APBuffer: PWideChar): PWideChar;
const
  MaxDigits = 16;
var
  LDigitBuffer: array[0..MaxDigits - 1] of WideChar;
  LCount: Cardinal;
  LDigit: NativeUInt;
begin
  {Generate the digits in the local buffer}
  LCount := 0;
  repeat
    LDigit := ANum;
    ANum := ANum div 16;
    LDigit := LDigit - ANum * 16;
    Inc(LCount);
    {HexTable holds AnsiChars;  the digits are all ASCII, so widening them one by
     one is exact.}
    LDigitBuffer[MaxDigits - LCount] := WideChar(HexTable[LDigit]);
  until ANum = 0;
  {Add leading zeros}
  while LCount < SizeOf(NativeUInt) * 2 do
  begin
    Inc(LCount);
    LDigitBuffer[MaxDigits - LCount] := WideChar('0');
  end;
  {Copy the digits to the output buffer and advance it}
  System.Move(LDigitBuffer[MaxDigits - LCount], APBuffer^, LCount * SizeOf(WideChar));
  Result := APBuffer + LCount;
end;

{Subroutine used by LogStackTrace}
procedure AppendInfoToString(var AString: string; const AInfo: string);
begin
  if AInfo <> '' then
    AString := Format('%s[%s]', [AString, AInfo]);
end;

var
  LReturnAddressInfoCache: TReturnAddressInfoCache;
  LLogStackTrace_Locked: Integer; //0 = unlocked, 1 = locked

function LogStackTraceW(AReturnAddresses: PNativeUInt; AMaxDepth: Cardinal;
  ABuffer, ABufferEnd: PWideChar): PWideChar;
const
  {Carriage return, line feed and the hexadecimal address.}
  CFixedCharsPerEntry = 2 + SizeOf(NativeUInt) * 2;
var
  LInd: Cardinal;
  LAddress: NativeUInt;
  LInfo: TJCLLocationInfo;
  LTempStr: string;
  P: PChar;
  LLocationCacheInitialized: Boolean;
  LPInfo: PReturnAddressInfo;
  LCharsToCopy: Integer;
begin
  LLocationCacheInitialized := False;

  Result := ABuffer;

  {This routine is protected by a lock - only one thread can be inside it at any given time.}
  while AtomicCmpExchange(LLogStackTrace_Locked, 1, 0) <> 0 do
    {Winapi.Windows.}SwitchToThread;

  try
    for LInd := 0 to AMaxDepth - 1 do
    begin
      LAddress := AReturnAddresses^;
      if LAddress = 0 then
        Exit;
      {Stop rather than run past the end of the caller's buffer.  The legacy
       entry point had no way to express this, which is the second reason for
       the new one.}
      if Result + CFixedCharsPerEntry > ABufferEnd then
        Exit;
      Result^ := WideChar(#13);
      Inc(Result);
      Result^ := WideChar(#10);
      Inc(Result);
      Result := NativeUIntToHexBuf(LAddress, Result);

      {If the info for the return address is not yet in the cache, add it.}
      LPInfo := LReturnAddressInfoCache.FindEntry(LAddress);

      if LPInfo = nil then
      begin
        if not LLocationCacheInitialized then
        begin
          {$if declared(BeginGetLocationInfoCache)} // available depending on the JCL's version
          BeginGetLocationInfoCache;
          {$IFEND}
          LLocationCacheInitialized := True;
        end;
        {Get location info for the caller (at least one byte before the return address).}
        GetLocationInfo(Pointer(LAddress - 1), LInfo);
        {Build the result string}
        LTempStr := ' ';
        AppendInfoToString(LTempStr, LInfo.SourceName);
        AppendInfoToString(LTempStr, LInfo.UnitName);

        {Remove UnitName from ProcedureName, no need to output it twice}
        P := PChar(LInfo.ProcedureName);
        if (StrLComp(P, PChar(LInfo.UnitName), Length(LInfo.UnitName)) = 0) and (P[Length(LInfo.UnitName)] = '.') then
          AppendInfoToString(LTempStr, Copy(LInfo.ProcedureName, Length(LInfo.UnitName) + 2{$IF CompilerVersion < 23},Length( LInfo.ProcedureName )-Length( LInfo.UnitName )-1{$IFEND}))
        else
          AppendInfoToString(LTempStr, LInfo.ProcedureName);

        if LInfo.LineNumber <> 0 then
          AppendInfoToString(LTempStr, IntToStr(LInfo.LineNumber));

        {No AnsiString round trip:  on a Unicode compiler LTempStr already holds
         whatever the source path contains, and casting it down to the ANSI code
         page is exactly what used to destroy it.  On a pre-Unicode compiler such
         as Delphi 7 the implicit widening below goes through the ANSI code page,
         which is the best that can be done when the JCL itself hands us ANSI
         text:  a single script non-Western path survives, mixed scripts cannot.}
        LPInfo := LReturnAddressInfoCache.AddEntry(LAddress, LTempStr);
        end;

      LCharsToCopy := LPInfo.InfoTextLength;
      if Result + LCharsToCopy > ABufferEnd then
        LCharsToCopy := ABufferEnd - Result;
      System.Move(LPInfo.InfoText, Result^, LCharsToCopy * SizeOf(WideChar));
      Inc(Result, LCharsToCopy);

      Inc(AReturnAddresses);
    end;
  finally
    if LLocationCacheInitialized then
    begin
      {$if declared(BeginGetLocationInfoCache)} // available depending on the JCL's version
      EndGetLocationInfoCache;
      {$IFEND}
    end;

    LLogStackTrace_Locked := 0;
  end;
end;

{The version 4 entry point, kept so that existing callers keep working:  FastMM4
 and versions of FastMM5 that do not know about LogStackTraceW still import this
 name.  It produces the same ANSI text as before, question marks and all - that
 is unavoidable through a PAnsiChar interface, and callers that want the source
 path intact should import LogStackTraceW instead.

 The legacy signature carries no buffer end, so the limit is derived the way the
 old implementation implicitly assumed it:  FastMM allows 256 characters per
 stack trace entry.}
function LogStackTrace(AReturnAddresses: PNativeUInt; AMaxDepth: Cardinal; ABuffer: PAnsiChar): PAnsiChar;
const
  CMaxCharsPerEntry = 256;
  {Bounds the local buffer.  FastMM never asks for more than 64 entries.}
  CMaxEntries = 64;
var
  LWideBuffer: array[0..CMaxEntries * CMaxCharsPerEntry - 1] of WideChar;
  LDepth: Cardinal;
  LWideStart, LWideEnd: PWideChar;
  LCharCount, LBytesWritten: Integer;
begin
  LDepth := AMaxDepth;
  if LDepth > CMaxEntries then
    LDepth := CMaxEntries;

  LWideStart := @LWideBuffer[0];
  LWideEnd := LogStackTraceW(AReturnAddresses, LDepth, LWideStart,
    LWideStart + LDepth * CMaxCharsPerEntry);
  LCharCount := LWideEnd - LWideStart;
  if LCharCount <= 0 then
  begin
    Result := ABuffer;
    Exit;
  end;

  {Down to the ANSI code page for the legacy caller.  Characters the code page
   cannot represent become the default replacement character, which is the loss
   this entry point exists to remain compatible with.}
  LBytesWritten := WideCharToMultiByte(CP_ACP, 0, @LWideBuffer[0], LCharCount,
    ABuffer, LCharCount, nil, nil);
  if LBytesWritten < 0 then
    LBytesWritten := 0;
  Result := ABuffer + LBytesWritten;
end;
{$endif}

{$ifdef madExcept}
function LogStackTrace(AReturnAddresses: PNativeUInt;
  AMaxDepth: Cardinal; ABuffer: PAnsiChar): PAnsiChar;
begin
  {Needs madExcept 2.7i or madExcept 3.0a or a newer build}
  Result := madStackTrace.FastMM_LogStackTrace(
    AReturnAddresses,
    AMaxDepth,
    ABuffer,
    {madExcept stack trace fine tuning}
    false, //hide items which have no line number information?
    true,  //show relative address offset to procedure entrypoint?
    true,  //show relative line number offset to procedure entry point?
    false  //skip special noise reduction processing?
    );
end;

{madStackTrace.FastMM_LogStackTrace only speaks PAnsiChar, but StackAddrToStr
 returns a UnicodeString for a single address, so the text can be assembled here
 without ever passing through the ANSI code page.  That makes this build as
 Unicode capable as the JCL one rather than merely converting correctly.

 madExcept formats the address into the line itself, so unlike the JCL branch
 this one does not prepend it.}
function LogStackTraceW(AReturnAddresses: PNativeUInt; AMaxDepth: Cardinal;
  ABuffer, ABufferEnd: PWideChar): PWideChar;
var
  LInd: Cardinal;
  LAddress: NativeUInt;
  LLine: UnicodeString;
  LCharsToCopy: Integer;
begin
  Result := ABuffer;
  for LInd := 0 to AMaxDepth - 1 do
  begin
    LAddress := AReturnAddresses^;
    if LAddress = 0 then
      Exit;

    LLine := madStackTrace.StackAddrToStr(Pointer(LAddress),
      True,  //show relative address offset to procedure entrypoint?
      True); //show relative line number offset to procedure entry point?

    if Result + 2 > ABufferEnd then
      Exit;
    Result^ := WideChar(#13);
    Inc(Result);
    Result^ := WideChar(#10);
    Inc(Result);

    LCharsToCopy := Length(LLine);
    if Result + LCharsToCopy > ABufferEnd then
      LCharsToCopy := ABufferEnd - Result;
    if LCharsToCopy > 0 then
    begin
      System.Move(Pointer(LLine)^, Result^, LCharsToCopy * SizeOf(WideChar));
      Inc(Result, LCharsToCopy);
    end;

    Inc(AReturnAddresses);
  end;
end;
{$endif}

{$ifdef EurekaLog_Legacy}
function LogStackTrace(AReturnAddresses: PNativeUInt; AMaxDepth: Cardinal;
  ABuffer: PAnsiChar): PAnsiChar;
begin
  {Needs EurekaLog 5 or 6}
  Result := ExceptionLog.FastMM_LogStackTrace(
    AReturnAddresses, AMaxDepth, ABuffer,
    {EurekaLog stack trace fine tuning}
    False, // Show the DLLs functions call.  <--|
           //                                   |-- See the note below!
    False, // Show the BPLs functions call.  <--|
    True  // Show relative line no. offset to procedure start point.
    );
// NOTE:
// -----
// With these values set both to "False", EurekaLog try to returns the best
// call-stack available.
//
// To do this EurekaLog execute the following points:
// --------------------------------------------------
// 1)...try to fill all call-stack items using only debug data with line no.
// 2)...if remains some empty call-stack items from the previous process (1),
//      EurekaLog try to fill these with the BPLs functions calls;
// 3)...if remains some empty call-stack items from the previous process (2),
//      EurekaLog try to fill these with the DLLs functions calls;
end;
{$endif}

{$ifdef EurekaLog_V7}
function LogStackTrace(AReturnAddresses: PNativeUInt; AMaxDepth: Cardinal; ABuffer: PAnsiChar): PAnsiChar;
begin
  {Needs EurekaLog 7 or later}
  Result := EFastMM4Support.FastMM_LogStackTrace(PPointer(AReturnAddresses), AMaxDepth, ABuffer, 10 * 256,
    [ddUnit, ddProcedure, ddSourceCode], True, False, False, True, False, True);
end;
{$endif}

{$IFDEF MACOS}

{Appends the source text to the destination and returns the new destination position}
function AppendStringToBuffer(const ASource, ADestination: PAnsiChar; ACount: Cardinal): PAnsiChar;
begin
  System.Move(ASource^, ADestination^, ACount);
  Result := Pointer(PByte(ADestination) + ACount);
end;

var
  MapFile: TSBMapFile;

function LogStackTrace(AReturnAddresses: PNativeUInt; AMaxDepth: Cardinal; ABuffer: PAnsiChar): PAnsiChar;
var
  s1: AnsiString;
  I: Integer;
  FileName: array[0..255] of AnsiChar;
  Len: Cardinal;
begin
  {$POINTERMATH ON}
//  writelN('LogStackTrace');
//  for I := 0 to AMaxDepth - 1 do
//    Writeln(IntToHex(AReturnAddresses[I], 8));

//  s1 := IntToHex(Integer(AReturnAddresses[0]), 8);
//  result := ABuffer;
//  Move(pointer(s1)^, result^, Length(s1));
//  inc(result, Length(s1));

  if MapFile = nil then
  begin
    MapFile := TSBMapFile.Create;
    Len := Length(FileName);
    _NSGetExecutablePath(@FileName[0], @Len);
    if FileExists(ChangeFileExt(FileName, '.map')) then
      MapFile.LoadFromFile(ChangeFileExt(FileName, '.map'));
  end;

  Result := ABuffer;

  s1 := #13#10;
  Result := AppendStringToBuffer(PAnsiChar(s1), Result, Length(s1));

  for I := 0 to AMaxDepth - 1 do
  begin
    s1 := IntToHex(AReturnAddresses[I], 8);
    s1 := s1 + ' ' + MapFile.GetFunctionName(AReturnAddresses[I]) + #13#10;
    Result := AppendStringToBuffer(PAnsiChar(s1), Result, Length(s1));
  end;

  {$POINTERMATH OFF}
end;
{$ENDIF}

{$IFDEF Win32}
function GetBriefSSEType: Cardinal;
type
  { Do not change registers order ! }
  TCPUIDStruct = packed record
    rEAX: Cardinal; { EAX Register }
    rEBX: Cardinal; { EBX Register }
    rEDX: Cardinal; { EDX Register }
    rECX: Cardinal; { ECX Register }
  end;
  PCPUIDStruct = ^TCPUIDStruct;
  
  function IsCPUIDSupported: Boolean;
  asm
    {$IFDEF CPUX64}
    PUSH RCX
    MOV RCX,RCX
    PUSHFQ
    POP RAX
    MOV RCX, RAX
    XOR RAX, $200000
    PUSH RAX
    POPFQ
    PUSHFQ
    POP RAX
    XOR RAX, RCX
    SHR RAX, 21
    AND RAX, 1
    PUSH RCX
    POPFQ
    POP RCX
    {$ELSE !CPUX64}

    PUSH ECX
    PUSHFD
    POP EAX { EAX = EFLAGS }
    MOV ECX, EAX  { Save the original EFLAGS value . }
    {
    CPUID is supported only if we can modify
    bit 21 of EFLAGS register !
     }
    XOR EAX, $200000
    PUSH EAX
    POPFD { Set the new EFLAGS value }
    PUSHFD
    POP EAX { Read EFLAGS }
    {
    Check if the 21 bit was modified !
    If so ==> Return True .
    else  ==> Return False.
     }
    XOR EAX, ECX
    SHR EAX, 21
    AND EAX, 1
    PUSH ECX
    POPFD  { Restore original EFLAGS value . }
    POP ECX
    {$ENDIF CPUX64}
  end;
  procedure CallCPUID(const ID: NativeInt; var CPUIDStruct);
  asm
    {
    ALL REGISTERS (rDX,rCX,rBX) MUST BE SAVED BEFORE
    EXECUTING CPUID INSTRUCTION !
     }
    {$IFDEF CPUX64}
    PUSH R9
    PUSH RBX
    PUSH RDX
    MOV RAX,RCX
    MOV R9,RDX
    CPUID
    {$IFNDEF FPC}
    MOV R9.TCPUIDStruct.rEAX,EAX
    MOV R9.TCPUIDStruct.rEBX,EBX
    MOV R9.TCPUIDStruct.rECX,ECX
    MOV R9.TCPUIDStruct.rEDX,EDX
    {$ELSE FPC}
    MOV [R9].TCPUIDStruct.rEAX,EAX
    MOV [R9].TCPUIDStruct.rEBX,EBX
    MOV [R9].TCPUIDStruct.rECX,ECX
    MOV [R9].TCPUIDStruct.rEDX,EDX
    {$ENDIF !FPC}
    POP RDX
    POP RBX
    POP R9
    {$ELSE !CPUX64}

    PUSH EDI
    PUSH ECX
    PUSH EBX
    MOV EDI,EDX
    CPUID
    {$IFNDEF FPC}
    MOV EDI.TCPUIDStruct.rEAX,EAX
    MOV EDI.TCPUIDStruct.rEBX,EBX
    MOV EDI.TCPUIDStruct.rECX,ECX
    MOV EDI.TCPUIDStruct.rEDX,EDX
    {$ELSE FPC}
    MOV [EDI].TCPUIDStruct.rEAX,EAX
    MOV [EDI].TCPUIDStruct.rEBX,EBX
    MOV [EDI].TCPUIDStruct.rECX,ECX
    MOV [EDI].TCPUIDStruct.rEDX,EDX
    {$ENDIF !FPC}
    POP EBX
    POP ECX
    POP EDI
    {$ENDIF CPUX64}
  end;
var
  Info: PCPUIDStruct;
begin
  Result := $00000000; // No SSE
  if not IsCPUIDSupported then
    Exit;
  Info := GetMemory(SizeOf(TCPUIDStruct));
  CallCPUID(1, Info^);

  if (Info^.rEDX and $02000000) <> 0 then // EDX 25 bits - SSE bit
    Result := Result or $00000001; // SSE supported
  if (Info^.rEDX and $04000000) <> 0 then // EDX 26 bits - SSE2 bit
    Result := Result or $00000002; // SSE2 supported

  FreeMemory(Info);
end;
{$ENDIF Win32}
{$if (not declared(LogStackTraceW))}
{The Unicode entry point for the builds that get their stack trace text from a
 third party library which offers no Unicode route of its own.  Those libraries
 hand out ANSI text, so a source path has already lost whatever the code page
 cannot represent before this library sees it - nothing here can bring that back.

 What it does fix is the other half of the problem:  the caller used to widen the
 ANSI text by assuming Latin-1, which mangles every code page that is not 1252.
 Converting through the actual code page instead means a Cyrillic path on a
 Russian system, or a Japanese path on a Japanese system, arrives intact.  Only
 scripts mixed within one path stay out of reach for these builds.}
function LogStackTraceW(AReturnAddresses: PNativeUInt; AMaxDepth: Cardinal;
  ABuffer, ABufferEnd: PWideChar): PWideChar;
const
  CMaxCharsPerEntry = 256;
  {FastMM never asks for more than 64 entries.}
  CMaxEntries = 64;
var
  LAnsiBuffer: array[0..CMaxEntries * CMaxCharsPerEntry - 1] of AnsiChar;
  LDepth: Cardinal;
  LAnsiEnd: PAnsiChar;
  LByteCount, LCharsAvailable: Integer;
{$IFNDEF MSWINDOWS}
  LWideText: TInfoString;
  LAnsiText: AnsiString;
{$ENDIF}
begin
  Result := ABuffer;

  LDepth := AMaxDepth;
  if LDepth > CMaxEntries then
    LDepth := CMaxEntries;

  LAnsiEnd := LogStackTrace(AReturnAddresses, LDepth, @LAnsiBuffer[0]);
  LByteCount := LAnsiEnd - @LAnsiBuffer[0];
  if LByteCount <= 0 then
    Exit;

  LCharsAvailable := ABufferEnd - ABuffer;
  if LCharsAvailable <= 0 then
    Exit;

{$IFDEF MSWINDOWS}
  Result := ABuffer + MultiByteToWideChar(CP_ACP, 0, @LAnsiBuffer[0], LByteCount,
    ABuffer, LCharsAvailable);
{$ELSE}
  {No Windows code page API here;  the RTL conversion is the platform correct
   one, which on POSIX means UTF-8 rather than a code page.}
  SetLength(LAnsiText, LByteCount);
  System.Move(LAnsiBuffer[0], Pointer(LAnsiText)^, LByteCount);
  LWideText := TInfoString(LAnsiText);
  if Length(LWideText) < LCharsAvailable then
    LCharsAvailable := Length(LWideText);
  System.Move(Pointer(LWideText)^, ABuffer^, LCharsAvailable * SizeOf(WideChar));
  Result := ABuffer + LCharsAvailable;
{$ENDIF}
end;
{$ifend}

{-----------------------------Exported Functions----------------------------}

exports
  GetFrameBasedStackTrace,
  GetRawStackTrace,
{$IFDEF MSWINDOWS}
  InvalidateMemoryPageAccessMap,
{$ENDIF}
  {The version 4 entry point.  Kept for callers that predate LogStackTraceW.}
  LogStackTrace,
  {Hands out the stack trace text as Unicode, and takes a buffer end so it
   cannot run past the caller's buffer.}
  LogStackTraceW;

begin
{$ifdef JCLDebug}
{$IF CompilerVersion < 23}
{$IF defined( Win32 )} // Win32 or OSX32
  TestSSE := GetBriefSSEType;
  DefaultMXCSR := GetMXCSR and $FFC0;  // Remove flag bits;
{$ELSEIF defined( Win64 )} // Win64
  TestSSE := $3; // SSE & SSE2 are available on X64
{$IFEND}
{$IFEND}

  JclStackTrackingOptions := JclStackTrackingOptions + [stAllModules];
{$endif}

{$IFDEF MSWINDOWS}

  {When this DLL is unloaded we need to unregister DLL load and unload notifications.}
  DLLProc := DllMain;

  {The memory map used by the stack tracing code must be updated whenever a DLL is loaded or unloaded.}
  RegisterDLLLoadAndUnloadNotifications;

{$ENDIF}

end.
