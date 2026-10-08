if(-not ('PokimonServerList' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;
using System.Text;
public static class PokimonServerList {
    static byte[] data; static int p;
    static void Need(int n) { if(n<0 || p>data.Length-n) throw new InvalidDataException("NBT incompleto"); }
    static byte B() { Need(1); return data[p++]; }
    static int U16() { return (B()<<8)|B(); }
    static int I32() { return (B()<<24)|(B()<<16)|(B()<<8)|B(); }
    static string S() { int n=U16(); Need(n); string v=Encoding.UTF8.GetString(data,p,n); p+=n; return v; }
    static void Skip(int type,int depth) {
        if(depth>64) throw new InvalidDataException("NBT demasiado profundo");
        int n;
        switch(type) {
          case 1: Need(1);p++;break; case 2: Need(2);p+=2;break;
          case 3: case 5: Need(4);p+=4;break;
          case 4: case 6: Need(8);p+=8;break;
          case 7: n=I32();Need(n);p+=n;break;
          case 8: S();break;
          case 9: int child=B();n=I32();if(n<0 || n>1000000) throw new InvalidDataException();for(int i=0;i<n;i++)Skip(child,depth+1);break;
          case 10: int tag;while((tag=B())!=0){S();Skip(tag,depth+1);}break;
          case 11: n=checked(I32()*4);Need(n);p+=n;break;
          case 12: n=checked(I32()*8);Need(n);p+=n;break;
          default: throw new InvalidDataException("Tipo NBT desconocido");
        }
    }
    static void W32(Stream s,int n) {s.WriteByte((byte)(n>>24));s.WriteByte((byte)(n>>16));s.WriteByte((byte)(n>>8));s.WriteByte((byte)n);}
    static void WS(Stream s,string text) {byte[] bytes=Encoding.UTF8.GetBytes(text);s.WriteByte((byte)(bytes.Length>>8));s.WriteByte((byte)bytes.Length);s.Write(bytes,0,bytes.Length);}
    static void Entry(Stream s) {s.WriteByte(8);WS(s,"name");WS(s,"Pokimon - partida compartida");s.WriteByte(8);WS(s,"ip");WS(s,"localhost:25565");s.WriteByte(0);}
    public static byte[] Add(byte[] input) {
        if(input==null || input.Length==0) {
            using(var output=new MemoryStream()){output.WriteByte(10);WS(output,"");output.WriteByte(9);WS(output,"servers");output.WriteByte(10);W32(output,1);Entry(output);output.WriteByte(0);return output.ToArray();}
        }
        if(input.Length>64*1024*1024) throw new InvalidDataException("Lista demasiado grande");
        if(input.Length>2 && input[0]==31 && input[1]==139) throw new InvalidDataException("Lista comprimida; anade localhost manualmente");
        data=input;p=0;
        if(B()!=10) throw new InvalidDataException("No es una lista de servidores NBT"); S();
        while(true) {
            int type=B();if(type==0)break;string name=S();
            if(type!=9 || name!="servers"){Skip(type,0);continue;}
            if(B()!=10) throw new InvalidDataException("Lista de tipo inesperado");
            int countOffset=p;int count=I32();if(count<0 || count>10000)throw new InvalidDataException();
            bool found=false;
            for(int i=0;i<count;i++) {
                int t;while((t=B())!=0){string key=S();if(t==8 && key=="ip"){string ip=S().Trim().ToLowerInvariant();if(ip=="localhost"||ip=="localhost:25565"||ip=="127.0.0.1"||ip=="127.0.0.1:25565")found=true;}else Skip(t,0);}
            }
            if(found)return null;
            int end=p;
            using(var output=new MemoryStream()){output.Write(input,0,countOffset);W32(output,count+1);output.Write(input,countOffset+4,end-countOffset-4);Entry(output);output.Write(input,end,input.Length-end);return output.ToArray();}
        }
        throw new InvalidDataException("No existe la lista servers; anade localhost manualmente");
    }
}
'@
}
function Add-PokimonClientEntry([string]$ProfileDirectory,[string]$StateDirectory) {
    $game=@(Get-CimInstance Win32_Process -Filter "Name='javaw.exe' OR Name='java.exe'" | Where-Object {$_.CommandLine -and ($_.CommandLine -like '*--gameDir*' -or $_.CommandLine -like '*net.minecraft.client*' -or $_.CommandLine -like '*KnotClient*')})
    if($game.Count -gt 0) {Write-Host 'Minecraft esta abierto: conserva tu lista actual. Anade localhost:25565 desde Multijugador.';return}
    $path=Join-Path $ProfileDirectory 'servers.dat'
    try {
        $before=$null
        if(Test-Path -LiteralPath $path) {$before=[IO.File]::ReadAllBytes($path)}
        $updated=[PokimonServerList]::Add($before)
        if($null -eq $updated) {return}
        if($before) {
            $backups=Join-Path $StateDirectory 'client-backups'
            [IO.Directory]::CreateDirectory($backups) | Out-Null
            Copy-Item -LiteralPath $path -Destination (Join-Path $backups ('servers-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)+'.dat'))
        }
        $temporary=$path+'.pokimon.tmp'
        [IO.File]::WriteAllBytes($temporary,$updated)
        if($before) {[IO.File]::Replace($temporary,$path,($path+'.pokimon.previous'))}else{[IO.File]::Move($temporary,$path)}
        Write-Host 'Anadido Pokimon a Multijugador en tu Modrinth.'
    } catch {Write-Warning ('No se cambio la lista de servidores: '+$_.Exception.Message+'. Puedes usar Conexion directa > localhost:25565.')}
}
