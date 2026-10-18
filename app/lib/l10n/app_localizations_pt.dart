// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class AppLocalizationsPt extends AppLocalizations {
  AppLocalizationsPt([String locale = 'pt']) : super(locale);

  @override
  String get appTitle => 'Siegel';

  @override
  String get continueButton => 'Continuar';

  @override
  String get welcomeTitle => 'Boas-vindas ao Siegel';

  @override
  String get historyNotice =>
      'Suas mensagens ficam salvas só neste celular. Se você perder, redefinir o aparelho ou apagar o app, seu histórico de conversas some para sempre. Não há backups.';

  @override
  String get phoneTitle => 'Seu número de telefone';

  @override
  String get phoneHint => '+55 11 90000 0000';

  @override
  String ageConfirm(int age) {
    return 'Tenho pelo menos $age anos';
  }

  @override
  String get sendCode => 'Enviar código';

  @override
  String codeTitle(String phone) {
    return 'Digite o código de 6 dígitos enviado para $phone';
  }

  @override
  String get codeLabel => 'Código';

  @override
  String get verify => 'Verificar';

  @override
  String get pinTitle => 'Bloqueio de registro';

  @override
  String get pinHelp =>
      'Este número está protegido por um PIN. Digite-o para continuar.';

  @override
  String get pinLabel => 'PIN de 4 dígitos';

  @override
  String get profileTitle => 'Seu perfil';

  @override
  String get usernameLabel => '@usuário';

  @override
  String get usernameHelp =>
      'De 4 a 32 caracteres: a–z, 0–9, _ e . Começa com uma letra. É assim que as pessoas encontram você.';

  @override
  String get displayNameLabel => 'Nome de exibição';

  @override
  String get save => 'Salvar';

  @override
  String get lockOfferTitle => 'Proteja sua conta com um PIN';

  @override
  String get lockOfferBody =>
      'Se alguém tomar seu número de telefone, também vai precisar deste PIN para registrá-lo. Não o esqueça.';

  @override
  String get setPin => 'Criar PIN';

  @override
  String get skip => 'Pular';

  @override
  String get skipWarningTitle => 'Pular o PIN?';

  @override
  String get skipWarningBody =>
      'Sem um PIN, qualquer pessoa que assumir seu número de telefone (por exemplo, clonando seu chip) pode tomar sua conta e seu @usuário.';

  @override
  String get skipAnyway => 'Pular mesmo assim';

  @override
  String get cancel => 'Cancelar';

  @override
  String homeRegistered(String username) {
    return 'Você é @$username';
  }

  @override
  String get settings => 'Configurações';

  @override
  String get deleteAccount => 'Excluir conta';

  @override
  String get deleteConfirmTitle => 'Excluir sua conta?';

  @override
  String get deleteConfirmBody =>
      'Sua conta, seu @usuário e todos os dados no nosso servidor são excluídos, e este celular é apagado. Não dá para desfazer.';

  @override
  String get delete => 'Excluir';

  @override
  String get errPhoneInvalid => 'Esse número de telefone não parece válido.';

  @override
  String get errRateLimited =>
      'Tentativas demais. Aguarde e tente de novo mais tarde.';

  @override
  String get errOtpInvalid => 'Código errado ou expirado.';

  @override
  String get errLockInvalid => 'PIN errado.';

  @override
  String get errLockLocked =>
      'PIN errado vezes demais. Tente de novo em 24 horas.';

  @override
  String get errUsernameInvalid => 'Esse nome de usuário não é permitido.';

  @override
  String get errUsernameTaken => 'Esse nome de usuário já está em uso.';

  @override
  String get errUsernameTooSoon =>
      'Você pode mudar seu nome de usuário uma vez a cada 30 dias.';

  @override
  String get errPinInvalid => 'O PIN deve ter exatamente 4 dígitos.';

  @override
  String get errDisplayNameInvalid => 'Digite um nome de 1 a 64 caracteres.';

  @override
  String get errNetwork =>
      'Não foi possível acessar o servidor. Verifique sua conexão.';

  @override
  String get errGeneric => 'Algo deu errado. Tente de novo.';

  @override
  String get appLock => 'Bloqueio do app';

  @override
  String get appLockSubtitle =>
      'Pedir sua digital, seu rosto ou a senha do celular para abrir o Siegel.';

  @override
  String get lockAfter => 'Bloquear após';

  @override
  String get lockImmediately => 'Imediatamente';

  @override
  String lockMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count minutos',
      one: '1 minuto',
    );
    return '$_temp0';
  }

  @override
  String lockHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count horas',
      one: '1 hora',
    );
    return '$_temp0';
  }

  @override
  String get screenSecurity => 'Segurança de tela';

  @override
  String get screenSecuritySubtitle =>
      'Bloquear capturas e gravações de tela do Siegel.';

  @override
  String get lockedTitle => 'O Siegel está bloqueado';

  @override
  String get unlock => 'Desbloquear';

  @override
  String get unlockReason => 'Desbloquear o Siegel';

  @override
  String get errNoDeviceLock =>
      'Não foi possível confirmar que é você. Configure primeiro um bloqueio de tela no celular.';

  @override
  String get appLogo => 'Logotipo do Siegel';

  @override
  String get chatsTitle => 'Conversas';

  @override
  String get newChat => 'Nova conversa';

  @override
  String get noChats =>
      'Nenhuma conversa ainda. Comece uma com o @usuário de alguém.';

  @override
  String get newContact => 'Novo contato';

  @override
  String get messageHint => 'Mensagem';

  @override
  String get send => 'Enviar';

  @override
  String get startChat => 'Iniciar conversa';

  @override
  String get errUsernameNotFound => 'Ninguém tem esse nome de usuário.';

  @override
  String get errNoKeyPackages =>
      'Essa conta não pode receber mensagens agora. Tente mais tarde.';

  @override
  String get errTextInvalid => 'As mensagens podem ter até 64 KB de texto.';

  @override
  String get messageRequests => 'Pedidos de mensagem';

  @override
  String messageRequestsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count pedidos de mensagem',
      one: '1 pedido de mensagem',
    );
    return '$_temp0';
  }

  @override
  String get noRequests => 'Nenhum pedido de mensagem.';

  @override
  String requestBanner(String name) {
    return '$name quer conversar com você. A pessoa não verá seu nome nem saberá que você leu isto até você aceitar.';
  }

  @override
  String get accept => 'Aceitar';

  @override
  String get block => 'Bloquear';

  @override
  String blockConfirmTitle(String name) {
    return 'Bloquear $name?';
  }

  @override
  String get blockConfirmBody =>
      'A pessoa não poderá enviar mensagens nem iniciar novas conversas com você, e não será avisada.';

  @override
  String get errRequestPending => 'Aceite o pedido antes de responder.';

  @override
  String get reply => 'Responder';

  @override
  String get copy => 'Copiar';

  @override
  String get copied => 'Copiado';

  @override
  String get edit => 'Editar';

  @override
  String get editing => 'Editando mensagem';

  @override
  String get edited => 'editada';

  @override
  String get editHistory => 'Histórico de edições';

  @override
  String get deleteForMe => 'Apagar para mim';

  @override
  String get deleteForEveryone => 'Apagar para todos';

  @override
  String get deleteForEveryoneBody =>
      'A mensagem é substituída por \"Esta mensagem foi apagada\" para todos nesta conversa. Alguém com um app modificado ainda poderia guardar uma cópia.';

  @override
  String get messageDeleted => 'Esta mensagem foi apagada';

  @override
  String get originalMissing => 'Mensagem original indisponível';

  @override
  String get you => 'Você';

  @override
  String get typing => 'digitando…';

  @override
  String get notSentRetry => 'Não enviada. Toque para tentar de novo.';

  @override
  String get statusSending => 'Enviando';

  @override
  String get statusSent => 'Enviada';

  @override
  String get statusDelivered => 'Entregue';

  @override
  String get statusRead => 'Lida';

  @override
  String get readReceipts => 'Confirmações de leitura';

  @override
  String get readReceiptsHelp =>
      'Se você desativar, também não verá quando outras pessoas lerem suas mensagens.';

  @override
  String get typingIndicators => 'Indicador de digitação';

  @override
  String get typingIndicatorsHelp =>
      'Se você desativar, também não verá quando outras pessoas estiverem digitando.';

  @override
  String get errNotAllowed => 'Isso não é mais possível para esta mensagem.';

  @override
  String get close => 'Fechar';

  @override
  String get safetyNumber => 'Número de segurança';

  @override
  String safetyNumberHelp(String name) {
    return 'Compare estes números com $name ou escaneie o código quando estiverem juntos. Se baterem, ninguém está no meio da conversa de vocês.';
  }

  @override
  String get safetyNumberUnavailable =>
      'O número de segurança ainda não está disponível.';

  @override
  String get scanCode => 'Escanear o código';

  @override
  String get verified => 'Verificado';

  @override
  String get verifiedDone => 'Verificado. O número de segurança confere.';

  @override
  String verifyMismatch(String name) {
    return 'Este código não confere. Escaneie o código de $name para esta conversa.';
  }

  @override
  String keyChanged(String name) {
    return 'O número de segurança de $name mudou, por exemplo porque reinstalou o Siegel ou trocou de celular. Toque para comparar.';
  }

  @override
  String get blockedPeople => 'Pessoas bloqueadas';

  @override
  String get noBlocked => 'Você não bloqueou ninguém.';

  @override
  String get unblock => 'Desbloquear';

  @override
  String get notificationChannel => 'Mensagens';

  @override
  String get errAttestation =>
      'Não foi possível verificar esta cópia do Siegel. Instale pelo Google Play e tente de novo.';

  @override
  String get theme => 'Tema';

  @override
  String get selected => 'Selecionado';

  @override
  String get themeSiegel => 'Selo. O verde do nosso logotipo.';

  @override
  String get themeDrache => 'Dragão. Vermelho intenso, um pouco feroz.';

  @override
  String get themeLoewe => 'Leão. Ouro velho, como um brasão.';

  @override
  String get themeLindwurm =>
      'O dragão-serpente das lendas alpinas. Verde-azulado e escamas.';

  @override
  String get themeSchnee => 'Neve. Azul-claro e tranquilo.';

  @override
  String get themeKrampus => 'O demônio de inverno dos Alpes. Laranja brasa.';

  @override
  String get themeNordlicht => 'Aurora boreal. Violeta com brilho.';

  @override
  String get themeFernweh => 'A vontade de ir para longe. Azul de mar aberto.';

  @override
  String get mute => 'Silenciar notificações';

  @override
  String get messageInfo => 'Dados da mensagem';

  @override
  String sentAt(String when) {
    return 'Enviada $when';
  }

  @override
  String get newGroup => 'Novo grupo';

  @override
  String get groupName => 'Nome do grupo';

  @override
  String get group => 'Grupo';

  @override
  String get addPeople => 'Adicionar pessoas';

  @override
  String get addPeopleHint => '@usuário e depois Adicionar';

  @override
  String get add => 'Adicionar';

  @override
  String get create => 'Criar';

  @override
  String membersCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count membros',
      one: '1 membro',
    );
    return '$_temp0';
  }

  @override
  String get groupInfo => 'Dados do grupo';

  @override
  String get admin => 'Admin';

  @override
  String get makeAdmin => 'Tornar admin';

  @override
  String get removeAdmin => 'Remover como admin';

  @override
  String get removeFromGroup => 'Remover do grupo';

  @override
  String get leaveGroup => 'Sair do grupo';

  @override
  String get leaveGroupBody =>
      'Você não vai receber novas mensagens deste grupo. A conversa fica neste celular.';

  @override
  String get leftGroup => 'Você não está mais neste grupo.';

  @override
  String get onlyAdminsEditInfo =>
      'Só admins podem mudar o nome e a foto do grupo';

  @override
  String get onlyAdminsAdd => 'Só admins podem adicionar membros';

  @override
  String get rename => 'Renomear';

  @override
  String isTyping(String name) {
    return '$name está digitando…';
  }

  @override
  String get someone => 'Alguém';

  @override
  String evCreated(String actor) {
    return '$actor criou o grupo';
  }

  @override
  String evAdded(String actor, String targets) {
    return '$actor adicionou $targets';
  }

  @override
  String evRemoved(String actor, String targets) {
    return '$actor removeu $targets';
  }

  @override
  String evLeft(String actor) {
    return '$actor saiu';
  }

  @override
  String evRenamed(String actor, String targets) {
    return '$actor renomeou o grupo para $targets';
  }

  @override
  String evAdminAdded(String actor, String targets) {
    return '$actor tornou $targets admin';
  }

  @override
  String evAdminRemoved(String actor, String targets) {
    return '$actor removeu $targets como admin';
  }

  @override
  String evSettings(String actor) {
    return '$actor mudou as configurações do grupo';
  }

  @override
  String get inviteBanner =>
      'Você foi adicionado a este grupo por alguém que não está nos seus contatos. Os membros não verão seu nome até você aceitar.';

  @override
  String get decline => 'Recusar';

  @override
  String get groupAdds => 'Quem pode me adicionar a grupos';

  @override
  String get groupAddsEveryone => 'Todos';

  @override
  String get groupAddsContacts => 'Meus contatos';

  @override
  String get groupAddsHelp =>
      'As demais pessoas enviam um convite para você aceitar ou recusar.';

  @override
  String get muteFor8h => 'Por 8 horas';

  @override
  String get muteFor1w => 'Por 1 semana';

  @override
  String get muteAlways => 'Sempre';

  @override
  String get unmute => 'Reativar som';

  @override
  String mutedUntil(String when) {
    return 'Silenciado até $when';
  }

  @override
  String get muted => 'Silenciado';

  @override
  String get errGroupLeft => 'Você não está mais neste grupo.';

  @override
  String get errGroupTooLarge => 'Os grupos podem ter até 256 membros.';

  @override
  String get errNameInvalid => 'Nomes de grupo têm de 1 a 64 caracteres.';

  @override
  String get editProfile => 'Editar perfil';

  @override
  String get orStartChat => 'Ou inicie uma conversa com o @usuário de alguém';

  @override
  String get errPeerOutdated =>
      'Alguém que você adicionou tem uma versão antiga do Siegel. É preciso atualizar antes de entrar em um grupo.';

  @override
  String get resendCode => 'Reenviar código';

  @override
  String resendIn(String time) {
    return 'Reenviar código em $time';
  }

  @override
  String get codeResent => 'Código reenviado.';

  @override
  String get errResendTooSoon =>
      'Aguarde um pouco antes de pedir outro código.';

  @override
  String get updateAvailable => 'Há uma nova versão do Siegel.';

  @override
  String get update => 'Atualizar';

  @override
  String get later => 'Depois';

  @override
  String get updateRequired =>
      'Esta versão do Siegel não é mais compatível. Atualize para continuar usando.';

  @override
  String get myLink => 'Meu link';

  @override
  String get myLinkSubtitle =>
      'Quem abrir conversa com você na hora, sem pedido.';

  @override
  String get myLinkHelp =>
      'Qualquer pessoa com este link ou código pode iniciar uma conversa com você sem pedido de mensagem. Escanear pessoalmente também verifica você.';

  @override
  String get showLink => 'Mostrar código';

  @override
  String get share => 'Compartilhar';

  @override
  String get resetLink => 'Redefinir link';

  @override
  String get resetLinkBody =>
      'Seu link e código antigos deixam de pular o pedido de mensagem. Compartilhe o novo com quem você quer que fale com você.';

  @override
  String get scanQr => 'Escanear um QR code';

  @override
  String get errLinkInvalid => 'Isso não é um link do Siegel.';

  @override
  String get errLinkKeyMismatch =>
      'Este link não corresponde à chave desta pessoa. Não confie nesta conversa; peça um link novo.';

  @override
  String joinGroupTitle(String name) {
    return 'Entrar em $name?';
  }

  @override
  String get join => 'Entrar';

  @override
  String get inviteLinks => 'Links de convite';

  @override
  String get newInviteLink => 'Criar link de convite';

  @override
  String get inviteLinkHelp =>
      'Qualquer pessoa com este link ou código pode entrar no grupo na hora, durante uma semana. Depois você pode remover pessoas ou revogar o link.';

  @override
  String expiresOn(String when) {
    return 'Expira $when';
  }

  @override
  String get revoke => 'Revogar';

  @override
  String get errLinkStale =>
      'O grupo acabou de mudar. Tente o link de novo daqui a pouco.';

  @override
  String get errInviteNotFound => 'Este link expirou ou foi revogado.';

  @override
  String get errAlreadyMember => 'Você já está neste grupo.';

  @override
  String get voiceMessage => 'Mensagem de voz';

  @override
  String get recordVoice => 'Gravar uma mensagem de voz';

  @override
  String get recording => 'Gravando';

  @override
  String get attachAudio => 'Enviar um arquivo de áudio';

  @override
  String get micDenied =>
      'O Siegel precisa do microfone para gravar mensagens de voz. Você pode permitir nas configurações do sistema.';

  @override
  String get play => 'Reproduzir';

  @override
  String get pause => 'Pausar';

  @override
  String get errAttachmentExpired =>
      'Este anexo não está mais no servidor. Peça para quem enviou mandar de novo.';

  @override
  String get errAttachmentCorrupt =>
      'Este anexo foi danificado no caminho e não pode ser aberto.';

  @override
  String get errAttachmentTooLarge => 'Os arquivos podem ter até 100 MB.';

  @override
  String get errUploadFailed => 'O envio não terminou. Tente de novo.';

  @override
  String get profilePhoto => 'Foto do perfil';

  @override
  String get choosePhoto => 'Escolher uma foto';

  @override
  String get removePhoto => 'Remover foto';

  @override
  String get errAvatarInvalid => 'Essa imagem não pode ser usada. Tente outra.';

  @override
  String evAvatar(String actor) {
    return '$actor mudou a foto do grupo';
  }

  @override
  String get themeEdelweiss =>
      'Edelvais, a flor-estrela dos Alpes. Branco neve até prata.';

  @override
  String get photo => 'Foto';

  @override
  String get video => 'Vídeo';

  @override
  String get file => 'Arquivo';

  @override
  String get attach => 'Anexar';

  @override
  String get download => 'Baixar';

  @override
  String get saveToDevice => 'Salvar no aparelho';

  @override
  String get forward => 'Encaminhar';

  @override
  String get forwardTo => 'Encaminhar para…';

  @override
  String get forwarded => 'Encaminhada';

  @override
  String get compressVideo => 'Comprimir o vídeo?';

  @override
  String get compressVideoBody =>
      'Um vídeo comprimido é menor e enviado mais rápido, com qualidade menor.';

  @override
  String get compressVideoMust =>
      'Este vídeo passa de 100 MB, o máximo que o Siegel envia. Comprima para enviar.';

  @override
  String get sendOriginal => 'Enviar original';

  @override
  String get compress => 'Comprimir';

  @override
  String get autoDownload => 'Download automático';

  @override
  String get autoDownloadHelp =>
      'O que é baixado sozinho ao chegar. Mensagens de voz são baixadas ao tocar.';

  @override
  String get onWifi => 'No Wi-Fi';

  @override
  String get onMobile => 'Nos dados móveis';

  @override
  String get photos => 'Fotos';

  @override
  String get videos => 'Vídeos';

  @override
  String get files => 'Arquivos';

  @override
  String get none => 'Nada';

  @override
  String get errAttachmentInvalid => 'Esse arquivo não pode ser enviado.';

  @override
  String get findContacts => 'Encontrar contatos';

  @override
  String get findContactsIntro =>
      'Veja quais pessoas dos contatos do seu celular usam o Siegel e ativaram \"Permitir que me encontrem pelo meu número\". Os números são verificados de um jeito que o servidor não os vê, e nada dos seus contatos fica guardado lá.';

  @override
  String get checkContacts => 'Verificar meus contatos';

  @override
  String get contactsDenied =>
      'O Siegel não consegue ler seus contatos. Você pode permitir nas configurações do celular.';

  @override
  String get noContactsFound =>
      'Nenhum dos seus contatos pode ser encontrado ainda. Eles aparecem aqui quando ativarem \"Permitir que me encontrem pelo meu número\".';

  @override
  String get discoverable => 'Permitir que me encontrem pelo meu número';

  @override
  String get discoverableHelp =>
      'Quem tem seu número nos contatos pode ver seu @usuário. Seu número não é mostrado a ninguém.';

  @override
  String get myNumberTitle => 'Seu número de celular';

  @override
  String get myNumberHelp => 'O número com que você se cadastrou';

  @override
  String get errPhoneMismatch =>
      'Este não é o número com que esta conta foi cadastrada.';

  @override
  String get sourceCode => 'Código-fonte';

  @override
  String get sourceCodeHelp => 'O Siegel é software livre (AGPL-3.0)';

  @override
  String get changeNumber => 'Mudar número';

  @override
  String get changeNumberHelp =>
      'Suas conversas, grupos, contatos e @usuário continuam como estão. Ninguém é avisado do seu novo número.';

  @override
  String get newNumber => 'Novo número de celular';

  @override
  String numberChanged(String number) {
    return 'Seu número agora é $number.';
  }

  @override
  String get noNumber =>
      'Sem número de celular: adicione um para poder recuperar sua conta';

  @override
  String get numberRemovedTitle => 'Seu número passou para outra conta';

  @override
  String get numberRemovedBody =>
      'Seu número foi verificado em outra conta do Siegel. Sua conta continua funcionando; adicione um número em Configurações para poder recuperá-la depois.';

  @override
  String get errNumberChangeTooSoon =>
      'Você pode mudar seu número uma vez a cada 7 dias.';

  @override
  String get errNumberSame => 'Esse já é o seu número.';
}
