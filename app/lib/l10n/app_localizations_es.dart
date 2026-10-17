// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get appTitle => 'Siegel';

  @override
  String get continueButton => 'Continuar';

  @override
  String get welcomeTitle => 'Te damos la bienvenida a Siegel';

  @override
  String get historyNotice =>
      'Tus mensajes solo se guardan en este teléfono. Si lo pierdes, lo restableces o borras la app, tu historial de chats desaparece para siempre. No hay copias de seguridad.';

  @override
  String get phoneTitle => 'Tu número de teléfono';

  @override
  String get phoneHint => '+34 600 000 000';

  @override
  String ageConfirm(int age) {
    return 'Tengo al menos $age años';
  }

  @override
  String get sendCode => 'Enviar código';

  @override
  String codeTitle(String phone) {
    return 'Introduce el código de 6 dígitos enviado a $phone';
  }

  @override
  String get codeLabel => 'Código';

  @override
  String get verify => 'Verificar';

  @override
  String get pinTitle => 'Bloqueo de registro';

  @override
  String get pinHelp =>
      'Este número está protegido con un PIN. Introdúcelo para continuar.';

  @override
  String get pinLabel => 'PIN de 4 dígitos';

  @override
  String get profileTitle => 'Tu perfil';

  @override
  String get usernameLabel => '@usuario';

  @override
  String get usernameHelp =>
      'De 4 a 32 caracteres: a–z, 0–9, _ y . Empieza por una letra. Así es como te encuentran.';

  @override
  String get displayNameLabel => 'Nombre visible';

  @override
  String get save => 'Guardar';

  @override
  String get lockOfferTitle => 'Protege tu cuenta con un PIN';

  @override
  String get lockOfferBody =>
      'Si alguien se hace con tu número de teléfono, también necesitará este PIN para registrarlo. No lo olvides.';

  @override
  String get setPin => 'Crear PIN';

  @override
  String get skip => 'Omitir';

  @override
  String get skipWarningTitle => '¿Omitir el PIN?';

  @override
  String get skipWarningBody =>
      'Sin PIN, cualquiera que se haga con tu número de teléfono (por ejemplo, duplicando tu SIM) puede quedarse con tu cuenta y tu @usuario.';

  @override
  String get skipAnyway => 'Omitir de todos modos';

  @override
  String get cancel => 'Cancelar';

  @override
  String homeRegistered(String username) {
    return 'Eres @$username';
  }

  @override
  String get settings => 'Ajustes';

  @override
  String get deleteAccount => 'Eliminar cuenta';

  @override
  String get deleteConfirmTitle => '¿Eliminar tu cuenta?';

  @override
  String get deleteConfirmBody =>
      'Se eliminan tu cuenta, tu @usuario y todos los datos de nuestro servidor, y se borra este teléfono. No se puede deshacer.';

  @override
  String get delete => 'Eliminar';

  @override
  String get errPhoneInvalid => 'Ese número de teléfono no parece válido.';

  @override
  String get errRateLimited =>
      'Demasiados intentos. Espera y vuelve a intentarlo más tarde.';

  @override
  String get errOtpInvalid => 'Código incorrecto o caducado.';

  @override
  String get errLockInvalid => 'PIN incorrecto.';

  @override
  String get errLockLocked =>
      'Demasiados PIN incorrectos. Vuelve a intentarlo en 24 horas.';

  @override
  String get errUsernameInvalid => 'Ese nombre de usuario no está permitido.';

  @override
  String get errUsernameTaken => 'Ese nombre de usuario ya existe.';

  @override
  String get errUsernameTooSoon =>
      'Puedes cambiar tu nombre de usuario una vez cada 30 días.';

  @override
  String get errPinInvalid => 'El PIN debe tener exactamente 4 dígitos.';

  @override
  String get errDisplayNameInvalid =>
      'Introduce un nombre de 1 a 64 caracteres.';

  @override
  String get errNetwork =>
      'No se puede conectar con el servidor. Comprueba tu conexión.';

  @override
  String get errGeneric => 'Algo ha fallado. Inténtalo de nuevo.';

  @override
  String get appLock => 'Bloqueo de la app';

  @override
  String get appLockSubtitle =>
      'Pide tu huella, tu cara o el código del teléfono para abrir Siegel.';

  @override
  String get lockAfter => 'Bloquear después de';

  @override
  String get lockImmediately => 'Inmediatamente';

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
  String get screenSecurity => 'Seguridad de pantalla';

  @override
  String get screenSecuritySubtitle =>
      'Impide capturas y grabaciones de pantalla de Siegel.';

  @override
  String get lockedTitle => 'Siegel está bloqueado';

  @override
  String get unlock => 'Desbloquear';

  @override
  String get unlockReason => 'Desbloquear Siegel';

  @override
  String get errNoDeviceLock =>
      'No se ha podido comprobar que eres tú. Configura primero un bloqueo de pantalla en tu teléfono.';

  @override
  String get appLogo => 'Logotipo de Siegel';

  @override
  String get chatsTitle => 'Chats';

  @override
  String get newChat => 'Nuevo chat';

  @override
  String get noChats =>
      'Aún no hay chats. Empieza uno con el @usuario de alguien.';

  @override
  String get newContact => 'Nuevo contacto';

  @override
  String get messageHint => 'Mensaje';

  @override
  String get send => 'Enviar';

  @override
  String get startChat => 'Iniciar chat';

  @override
  String get errUsernameNotFound => 'Nadie tiene ese nombre de usuario.';

  @override
  String get errNoKeyPackages =>
      'Esa cuenta no puede recibir mensajes ahora mismo. Inténtalo más tarde.';

  @override
  String get errTextInvalid =>
      'Los mensajes pueden tener hasta 64 KB de texto.';

  @override
  String get messageRequests => 'Solicitudes de mensaje';

  @override
  String messageRequestsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count solicitudes de mensaje',
      one: '1 solicitud de mensaje',
    );
    return '$_temp0';
  }

  @override
  String get noRequests => 'No hay solicitudes de mensaje.';

  @override
  String requestBanner(String name) {
    return '$name quiere chatear contigo. No verá tu nombre ni sabrá que has leído esto hasta que aceptes.';
  }

  @override
  String get accept => 'Aceptar';

  @override
  String get block => 'Bloquear';

  @override
  String blockConfirmTitle(String name) {
    return '¿Bloquear a $name?';
  }

  @override
  String get blockConfirmBody =>
      'No podrá enviarte mensajes ni iniciar chats nuevos, y no se le avisará.';

  @override
  String get errRequestPending => 'Acepta la solicitud antes de responder.';

  @override
  String get reply => 'Responder';

  @override
  String get copy => 'Copiar';

  @override
  String get copied => 'Copiado';

  @override
  String get edit => 'Editar';

  @override
  String get editing => 'Editando mensaje';

  @override
  String get edited => 'editado';

  @override
  String get editHistory => 'Historial de ediciones';

  @override
  String get deleteForMe => 'Eliminar para mí';

  @override
  String get deleteForEveryone => 'Eliminar para todos';

  @override
  String get deleteForEveryoneBody =>
      'El mensaje se sustituye por «Se eliminó este mensaje» para todos en este chat. Alguien con una app modificada podría guardar una copia.';

  @override
  String get messageDeleted => 'Se eliminó este mensaje';

  @override
  String get originalMissing => 'El mensaje original no está disponible';

  @override
  String get you => 'Tú';

  @override
  String get typing => 'escribiendo…';

  @override
  String get notSentRetry => 'No enviado. Toca para reintentar.';

  @override
  String get statusSending => 'Enviando';

  @override
  String get statusSent => 'Enviado';

  @override
  String get statusDelivered => 'Entregado';

  @override
  String get statusRead => 'Leído';

  @override
  String get readReceipts => 'Confirmaciones de lectura';

  @override
  String get readReceiptsHelp =>
      'Si las desactivas, tampoco verás cuándo leen otros tus mensajes.';

  @override
  String get typingIndicators => 'Indicador de escritura';

  @override
  String get typingIndicatorsHelp =>
      'Si lo desactivas, tampoco verás cuándo escriben otros.';

  @override
  String get errNotAllowed => 'Eso ya no es posible para este mensaje.';

  @override
  String get close => 'Cerrar';

  @override
  String get safetyNumber => 'Número de seguridad';

  @override
  String safetyNumberHelp(String name) {
    return 'Compara estos números con $name o escanea su código cuando estéis juntos. Si coinciden, nadie se interpone en vuestro chat.';
  }

  @override
  String get safetyNumberUnavailable =>
      'El número de seguridad aún no está disponible.';

  @override
  String get scanCode => 'Escanear su código';

  @override
  String get verified => 'Verificado';

  @override
  String get verifiedDone => 'Verificado. El número de seguridad coincide.';

  @override
  String verifyMismatch(String name) {
    return 'Este código no coincide. Asegúrate de escanear el código de $name para este chat.';
  }

  @override
  String keyChanged(String name) {
    return 'El número de seguridad de $name ha cambiado, por ejemplo porque ha reinstalado Siegel o tiene un teléfono nuevo. Toca para comparar.';
  }

  @override
  String get blockedPeople => 'Personas bloqueadas';

  @override
  String get noBlocked => 'No has bloqueado a nadie.';

  @override
  String get unblock => 'Desbloquear';

  @override
  String get notificationChannel => 'Mensajes';

  @override
  String get errAttestation =>
      'No se ha podido verificar esta copia de Siegel. Instálala desde Google Play y vuelve a intentarlo.';

  @override
  String get theme => 'Tema';

  @override
  String get selected => 'Seleccionado';

  @override
  String get themeSiegel => 'Sello. El verde de nuestro logotipo.';

  @override
  String get themeDrache => 'Dragón. Rojo intenso, algo feroz.';

  @override
  String get themeLoewe => 'León. Oro viejo, como un escudo de armas.';

  @override
  String get themeLindwurm =>
      'El dragón serpiente de las leyendas alpinas. Verde azulado y escamas.';

  @override
  String get themeSchnee => 'Nieve. Azul pálido y tranquilo.';

  @override
  String get themeKrampus => 'El demonio invernal de los Alpes. Naranja brasa.';

  @override
  String get themeNordlicht => 'Aurora boreal. Violeta con destellos.';

  @override
  String get themeFernweh => 'Las ganas de viajar lejos. Azul de mar abierto.';

  @override
  String get mute => 'Silenciar notificaciones';

  @override
  String get messageInfo => 'Info. del mensaje';

  @override
  String sentAt(String when) {
    return 'Enviado $when';
  }

  @override
  String get newGroup => 'Nuevo grupo';

  @override
  String get groupName => 'Nombre del grupo';

  @override
  String get group => 'Grupo';

  @override
  String get addPeople => 'Añadir personas';

  @override
  String get addPeopleHint => '@usuario y luego Añadir';

  @override
  String get add => 'Añadir';

  @override
  String get create => 'Crear';

  @override
  String membersCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count miembros',
      one: '1 miembro',
    );
    return '$_temp0';
  }

  @override
  String get groupInfo => 'Info. del grupo';

  @override
  String get admin => 'Admin';

  @override
  String get makeAdmin => 'Hacer admin';

  @override
  String get removeAdmin => 'Quitar como admin';

  @override
  String get removeFromGroup => 'Eliminar del grupo';

  @override
  String get leaveGroup => 'Salir del grupo';

  @override
  String get leaveGroupBody =>
      'No recibirás mensajes nuevos de este grupo. El chat se queda en este teléfono.';

  @override
  String get leftGroup => 'Ya no estás en este grupo.';

  @override
  String get onlyAdminsEditInfo =>
      'Solo los admins pueden cambiar el nombre y la foto del grupo';

  @override
  String get onlyAdminsAdd => 'Solo los admins pueden añadir miembros';

  @override
  String get rename => 'Cambiar nombre';

  @override
  String isTyping(String name) {
    return '$name está escribiendo…';
  }

  @override
  String get someone => 'Alguien';

  @override
  String evCreated(String actor) {
    return '$actor creó el grupo';
  }

  @override
  String evAdded(String actor, String targets) {
    return '$actor añadió a $targets';
  }

  @override
  String evRemoved(String actor, String targets) {
    return '$actor eliminó a $targets';
  }

  @override
  String evLeft(String actor) {
    return '$actor salió';
  }

  @override
  String evRenamed(String actor, String targets) {
    return '$actor cambió el nombre del grupo a $targets';
  }

  @override
  String evAdminAdded(String actor, String targets) {
    return '$actor hizo admin a $targets';
  }

  @override
  String evAdminRemoved(String actor, String targets) {
    return '$actor quitó a $targets como admin';
  }

  @override
  String evSettings(String actor) {
    return '$actor cambió los ajustes del grupo';
  }

  @override
  String get inviteBanner =>
      'Te ha añadido a este grupo alguien que no está en tus contactos. Los miembros no verán tu nombre hasta que aceptes.';

  @override
  String get decline => 'Rechazar';

  @override
  String get groupAdds => 'Quién puede añadirme a grupos';

  @override
  String get groupAddsEveryone => 'Todos';

  @override
  String get groupAddsContacts => 'Mis contactos';

  @override
  String get groupAddsHelp =>
      'Los demás te envían una invitación que puedes aceptar o rechazar.';

  @override
  String get muteFor8h => 'Durante 8 horas';

  @override
  String get muteFor1w => 'Durante 1 semana';

  @override
  String get muteAlways => 'Siempre';

  @override
  String get unmute => 'Activar sonido';

  @override
  String mutedUntil(String when) {
    return 'Silenciado hasta $when';
  }

  @override
  String get muted => 'Silenciado';

  @override
  String get errGroupLeft => 'Ya no estás en este grupo.';

  @override
  String get errGroupTooLarge => 'Los grupos pueden tener hasta 256 miembros.';

  @override
  String get errNameInvalid =>
      'Los nombres de grupo tienen de 1 a 64 caracteres.';

  @override
  String get editProfile => 'Editar perfil';

  @override
  String get orStartChat => 'O inicia un chat con el @usuario de alguien';

  @override
  String get errPeerOutdated =>
      'Alguien que has añadido tiene una versión antigua de Siegel. Debe actualizarla para unirse a un grupo.';

  @override
  String get resendCode => 'Reenviar código';

  @override
  String resendIn(String time) {
    return 'Reenviar código en $time';
  }

  @override
  String get codeResent => 'Código reenviado.';

  @override
  String get errResendTooSoon => 'Espera un poco antes de pedir otro código.';

  @override
  String get updateAvailable => 'Hay una nueva versión de Siegel.';

  @override
  String get update => 'Actualizar';

  @override
  String get later => 'Más tarde';

  @override
  String get updateRequired =>
      'Esta versión de Siegel ya no es compatible. Actualiza para seguir usándola.';

  @override
  String get myLink => 'Mi enlace';

  @override
  String get myLinkSubtitle =>
      'Quien lo abra chatea contigo directamente, sin solicitud.';

  @override
  String get myLinkHelp =>
      'Cualquiera con este enlace o código puede iniciar un chat contigo sin solicitud de mensaje. Escanearlo en persona también te verifica.';

  @override
  String get showLink => 'Mostrar código';

  @override
  String get share => 'Compartir';

  @override
  String get resetLink => 'Restablecer enlace';

  @override
  String get resetLinkBody =>
      'Tu enlace y código anteriores dejan de saltarse la solicitud de mensaje. Comparte el nuevo con quien quieras que te escriba.';

  @override
  String get scanQr => 'Escanear un código QR';

  @override
  String get errLinkInvalid => 'Eso no es un enlace de Siegel.';

  @override
  String get errLinkKeyMismatch =>
      'Este enlace no coincide con la clave de esta persona. No confíes en este chat; pídele un enlace nuevo.';

  @override
  String joinGroupTitle(String name) {
    return '¿Unirte a $name?';
  }

  @override
  String get join => 'Unirme';

  @override
  String get inviteLinks => 'Enlaces de invitación';

  @override
  String get newInviteLink => 'Crear enlace de invitación';

  @override
  String get inviteLinkHelp =>
      'Cualquiera con este enlace o código puede unirse al grupo directamente durante una semana. Después puedes eliminar a quien quieras o revocar el enlace.';

  @override
  String expiresOn(String when) {
    return 'Caduca $when';
  }

  @override
  String get revoke => 'Revocar';

  @override
  String get errLinkStale =>
      'El grupo acaba de cambiar. Vuelve a probar el enlace en un momento.';

  @override
  String get errInviteNotFound => 'Este enlace ha caducado o se ha revocado.';

  @override
  String get errAlreadyMember => 'Ya estás en este grupo.';

  @override
  String get voiceMessage => 'Mensaje de voz';

  @override
  String get recordVoice => 'Grabar un mensaje de voz';

  @override
  String get recording => 'Grabando';

  @override
  String get attachAudio => 'Enviar un archivo de audio';

  @override
  String get micDenied =>
      'Siegel necesita el micrófono para grabar mensajes de voz. Puedes permitirlo en los ajustes del sistema.';

  @override
  String get play => 'Reproducir';

  @override
  String get pause => 'Pausar';

  @override
  String get errAttachmentExpired =>
      'Este archivo ya no está en el servidor. Pide a quien lo envió que lo vuelva a enviar.';

  @override
  String get errAttachmentCorrupt =>
      'Este archivo se dañó por el camino y no se puede abrir.';

  @override
  String get errAttachmentTooLarge =>
      'Los archivos pueden ocupar hasta 100 MB.';

  @override
  String get errUploadFailed =>
      'La subida no ha terminado. Inténtalo de nuevo.';

  @override
  String get profilePhoto => 'Foto de perfil';

  @override
  String get choosePhoto => 'Elegir una foto';

  @override
  String get removePhoto => 'Quitar foto';

  @override
  String get errAvatarInvalid =>
      'Esa imagen no se puede usar. Prueba con otra.';

  @override
  String evAvatar(String actor) {
    return '$actor cambió la foto del grupo';
  }

  @override
  String get themeEdelweiss =>
      'Edelweiss, la flor estrella de los Alpes. Blanco nieve hacia plata.';
}
