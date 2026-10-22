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

  @override
  String get photo => 'Foto';

  @override
  String get video => 'Vídeo';

  @override
  String get file => 'Archivo';

  @override
  String get attach => 'Adjuntar';

  @override
  String get download => 'Descargar';

  @override
  String get saveToDevice => 'Guardar en el dispositivo';

  @override
  String get forward => 'Reenviar';

  @override
  String get forwardTo => 'Reenviar a…';

  @override
  String get forwarded => 'Reenviado';

  @override
  String get compressVideo => '¿Comprimir el vídeo?';

  @override
  String get compressVideoBody =>
      'Un vídeo comprimido ocupa menos y se envía antes, con menos calidad.';

  @override
  String get compressVideoMust =>
      'Este vídeo supera los 100 MB, el máximo que Siegel puede enviar. Comprímelo para enviarlo.';

  @override
  String get sendOriginal => 'Enviar original';

  @override
  String get compress => 'Comprimir';

  @override
  String get autoDownload => 'Descarga automática';

  @override
  String get autoDownloadHelp =>
      'Lo que se descarga solo al llegar. Los mensajes de voz se descargan al reproducirlos.';

  @override
  String get onWifi => 'Con Wi-Fi';

  @override
  String get onMobile => 'Con datos móviles';

  @override
  String get photos => 'Fotos';

  @override
  String get videos => 'Vídeos';

  @override
  String get files => 'Archivos';

  @override
  String get none => 'Nada';

  @override
  String get errAttachmentInvalid => 'Ese archivo no se puede enviar.';

  @override
  String get findContacts => 'Buscar contactos';

  @override
  String get findContactsIntro =>
      'Mira qué personas de los contactos de tu teléfono usan Siegel y activaron \"Permitir que me encuentren por mi número\". Sus números se comprueban de forma que el servidor no los ve, y no se guarda allí nada de tus contactos.';

  @override
  String get checkContacts => 'Comprobar mis contactos';

  @override
  String get contactsDenied =>
      'Siegel no puede leer tus contactos. Puedes permitirlo en los ajustes del teléfono.';

  @override
  String get noContactsFound =>
      'Todavía no se puede encontrar a ninguno de tus contactos. Aparecerán aquí cuando activen \"Permitir que me encuentren por mi número\".';

  @override
  String get discoverable => 'Permitir que me encuentren por mi número';

  @override
  String get discoverableHelp =>
      'Quien tenga tu número en sus contactos puede ver tu @usuario. Tu número no se muestra a nadie.';

  @override
  String get myNumberTitle => 'Tu número de teléfono';

  @override
  String get myNumberHelp => 'El número con el que te registraste';

  @override
  String get errPhoneMismatch =>
      'Ese no es el número con el que se registró esta cuenta.';

  @override
  String get sourceCode => 'Código fuente';

  @override
  String get sourceCodeHelp => 'Siegel es software libre (AGPL-3.0)';

  @override
  String get changeNumber => 'Cambiar número';

  @override
  String get changeNumberHelp =>
      'Tus chats, grupos, contactos y @usuario se quedan como están. No se avisa a nadie de tu nuevo número.';

  @override
  String get newNumber => 'Nuevo número de teléfono';

  @override
  String numberChanged(String number) {
    return 'Tu número ahora es $number.';
  }

  @override
  String get noNumber =>
      'Sin número de teléfono: añade uno para poder recuperar tu cuenta';

  @override
  String get numberRemovedTitle => 'Tu número pasó a otra cuenta';

  @override
  String get numberRemovedBody =>
      'Tu número se verificó en otra cuenta de Siegel. Tu cuenta sigue funcionando; añade un número en Ajustes para poder recuperarla más adelante.';

  @override
  String get errNumberChangeTooSoon =>
      'Puedes cambiar tu número una vez cada 7 días.';

  @override
  String get errNumberSame => 'Ese ya es tu número.';

  @override
  String get skTitle => 'Lo que Siegel sabe de mí';

  @override
  String get skHelp => 'Todo lo que el servidor guarda sobre tu cuenta';

  @override
  String get skIntro =>
      'Esto es todo lo que el servidor de Siegel guarda sobre tu cuenta, consultado ahora mismo. No puede leer tus mensajes, tus contactos ni tu perfil.';

  @override
  String get skAccount => 'Cuenta';

  @override
  String get skCreated => 'Cuenta creada';

  @override
  String get skPhone => 'Número de teléfono';

  @override
  String skPhoneHash(String hash) {
    return 'Solo se guarda como un código que no se puede convertir de nuevo en tu número: $hash';
  }

  @override
  String get skNumberChanged => 'Último cambio de número';

  @override
  String get skUsername => 'Nombre de usuario';

  @override
  String skUsernameSince(String username, String day) {
    return '@$username, desde el $day';
  }

  @override
  String get skReleased =>
      'Nombres de usuario antiguos que aún puedes recuperar';

  @override
  String get skIdentityKey => 'Clave de identidad';

  @override
  String skIdentityKeyHelp(String key) {
    return 'Pública. Otros la usan para comprobar que los mensajes vienen de ti: $key';
  }

  @override
  String get skOn => 'Activado';

  @override
  String get skOff => 'Desactivado';

  @override
  String get skProfile => 'Perfil';

  @override
  String get skProfileStored =>
      'Tu nombre e información, cifrados. Solo las personas con las que chateas pueden leerlos.';

  @override
  String get skProfilePicture => 'Foto de perfil';

  @override
  String get skPictureStored =>
      'Cifrada. Solo las personas con las que chateas pueden verla.';

  @override
  String get skChecked => 'Números de contactos comprobados recientemente';

  @override
  String skCheckedCount(int count) {
    return '$count. Solo cuántos, nunca cuáles.';
  }

  @override
  String get skDevices => 'Dispositivos';

  @override
  String get skThisDevice => 'Este teléfono';

  @override
  String get skOtherDevice => 'Otro dispositivo';

  @override
  String skLastSeen(String platform, String day) {
    return '$platform, última conexión el $day';
  }

  @override
  String skQueued(int count) {
    return 'Mensajes cifrados en espera: $count';
  }

  @override
  String skKeys(int count) {
    return 'Claves para iniciar chats: $count';
  }

  @override
  String get skPushYes => 'Token de notificaciones: guardado';

  @override
  String get skPushNo => 'Token de notificaciones: ninguno';

  @override
  String get skCopyJson => 'Copiar como JSON';

  @override
  String unreadCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count mensajes sin leer',
      one: '1 mensaje sin leer',
    );
    return '$_temp0';
  }

  @override
  String get messageOptions => 'Opciones del mensaje';

  @override
  String get themeKraehe => 'Cuervo. Azul medianoche hasta negro.';

  @override
  String get chatBackground => 'Fondo del chat';

  @override
  String get backgroundPattern => 'El motivo del tema';

  @override
  String get backgroundPlain => 'Liso';

  @override
  String get backgroundPhoto => 'Mi foto';

  @override
  String get archive => 'Archivar';

  @override
  String get unarchive => 'Desarchivar';

  @override
  String get archived => 'Archivados';

  @override
  String get noArchived => 'No hay chats archivados.';

  @override
  String unreadChats(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count chats con mensajes sin leer',
      one: '1 chat con mensajes sin leer',
    );
    return '$_temp0';
  }

  @override
  String get deleteChat => 'Eliminar chat';

  @override
  String deleteChatTitle(String name) {
    return '¿Eliminar el chat con $name?';
  }

  @override
  String get deleteChatBody =>
      'Sus mensajes se eliminan de este teléfono. Si te vuelve a escribir, el chat reaparece.';

  @override
  String leaveAndDeleteTitle(String name) {
    return '¿Salir de $name y eliminar el chat?';
  }

  @override
  String get leaveAndDeleteBody =>
      'Los miembros verán que saliste. Los mensajes se eliminan de este teléfono.';

  @override
  String get moreReactions => 'Más reacciones';

  @override
  String get sticker => 'Sticker';

  @override
  String get stickers => 'Stickers';

  @override
  String get myStickers => 'Míos';

  @override
  String get noStickers =>
      'Crea uno a partir de una foto, o mantén pulsado un sticker en un chat y añádelo aquí.';

  @override
  String get stickerFromPhoto => 'De una foto';

  @override
  String get importStickerPack => 'Importar paquete';

  @override
  String removeStickerPack(String pack) {
    return 'Quitar el paquete $pack';
  }

  @override
  String get removeSticker => '¿Quitar este sticker?';

  @override
  String get addToMyStickers => 'Añadir a mis stickers';

  @override
  String get stickerAdded => 'Añadido a tus stickers.';

  @override
  String get errStickerInvalid =>
      'Eso no puede ser un sticker: WebP o PNG, hasta 1 MB.';

  @override
  String get termsAndGuidelines => 'Términos y normas de la comunidad';

  @override
  String get privacyPolicy => 'Política de privacidad';

  @override
  String get terms => 'Términos';

  @override
  String get guidelines => 'Normas';

  @override
  String get agreeToTerms => 'Al continuar aceptas nuestros';

  @override
  String get birthMonth => 'Mes de nacimiento';

  @override
  String get birthYear => 'Año de nacimiento';

  @override
  String get birthTitle => '¿Cuándo naciste?';

  @override
  String get birthWhy =>
      'Siegel protege a los menores de 18: los desconocidos no pueden encontrarlos por su @usuario, y solo sus contactos pueden añadirlos a grupos. Tu fecha de nacimiento se queda en este teléfono; solo sabemos si tienes menos de 18.';

  @override
  String tooYoung(int age) {
    return 'Siegel es para personas de $age años o más.';
  }

  @override
  String get groupAddsMinor => 'Solo contactos: tienes menos de 18.';

  @override
  String get skMinor => 'Menor de 18';

  @override
  String get yes => 'Sí';

  @override
  String get no => 'No';

  @override
  String get tapToView => 'De alguien que no has aceptado. Toca para ver.';

  @override
  String get report => 'Denunciar';

  @override
  String get reportGroup => 'Denunciar grupo';

  @override
  String get reportWhy => '¿Qué pasa?';

  @override
  String get reportSpam => 'Spam o estafa';

  @override
  String get reportHarassment => 'Acoso o amenazas';

  @override
  String get reportHate => 'Odio';

  @override
  String get reportChildSafety => 'Contenido sexual con un menor';

  @override
  String get reportNonConsensual => 'Otro contenido sexual sin consentimiento';

  @override
  String get reportViolence => 'Violencia o terrorismo';

  @override
  String get reportImpersonation => 'Se hace pasar por otra persona';

  @override
  String get reportOther => 'Otra cosa';

  @override
  String get reportChildSafetyHelp =>
      'Los revisamos primero, en menos de 24 horas. Si tienes menos de 18, cuéntaselo también a un adulto de confianza. No has hecho nada malo.';

  @override
  String reportMessages(int count, int max) {
    return 'Mensajes a enviar ($count de $max)';
  }

  @override
  String get reportReadable =>
      'Estos mensajes se enviarán a los moderadores de Siegel, legibles. A la persona no se le dice quién la denunció.';

  @override
  String get reportNote => '¿Algo más que debamos saber? (opcional)';

  @override
  String reportAlsoBlock(String name) {
    return 'Bloquear también a $name';
  }

  @override
  String get reportSend => 'Enviar denuncia';

  @override
  String get reportSent => 'Gracias. Tu denuncia se ha enviado.';

  @override
  String get reportAndBlock => 'Denunciar y bloquear';

  @override
  String get errReportsUnavailable =>
      'Las denuncias aún no están disponibles. Escríbenos a la dirección de la página de Términos.';

  @override
  String get errReportInvalid => 'No se pudo enviar la denuncia.';

  @override
  String get suspendedTitle => 'Tu cuenta está suspendida';

  @override
  String suspendedUntil(String date) {
    return 'No puedes enviar ni recibir mensajes hasta el $date.';
  }

  @override
  String noticeRule(String rule) {
    return 'Norma: $rule';
  }

  @override
  String get appealHow =>
      '¿Crees que es un error? Escribe a la dirección de nuestra página de Términos. Una persona revisa cada recurso.';

  @override
  String get usernameRemoved =>
      'Nuestros moderadores han quitado tu @usuario. Elige uno nuevo.';

  @override
  String get errNumberBanned =>
      'Este número no puede usar Siegel. ¿Crees que es un error? Escribe a la dirección de nuestra página de Términos.';

  @override
  String get stickerText => 'Texto';

  @override
  String get editSticker => 'Editar sticker';

  @override
  String get addText => 'Añadir texto';

  @override
  String get stickerTextHelp =>
      'Arrastra el texto para moverlo; tócalo dos veces para cambiarlo.';

  @override
  String get textSize => 'Tamaño del texto';

  @override
  String get removeText => 'Quitar texto';

  @override
  String get importStickers => 'Importar';

  @override
  String stickersAdded(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count stickers añadidos.',
      one: '1 sticker añadido.',
      zero: 'No se encontraron stickers.',
    );
    return '$_temp0';
  }

  @override
  String reportsReviewed(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Hemos revisado $count de tus denuncias. Gracias por avisarnos.',
      one: 'Hemos revisado tu denuncia. Gracias por avisarnos.',
    );
    return '$_temp0';
  }

  @override
  String get linkedDevices => 'Dispositivos vinculados';

  @override
  String get linkedDevicesHint => 'Usa Siegel en un navegador';

  @override
  String get linkedDevicesHelp =>
      'Usa Siegel en hasta 4 dispositivos más, como un navegador en web.siegel.schlk.in. Reciben los mensajes nuevos desde que los vinculas, no tu historial.';

  @override
  String get thisIsLinked =>
      'Este es un dispositivo vinculado. Vincula o desvincula dispositivos desde tu teléfono.';

  @override
  String get mainPhone => 'Teléfono';

  @override
  String get thisDevice => 'Este dispositivo';

  @override
  String lastActive(String day) {
    return 'Activo por última vez el $day';
  }

  @override
  String get linkDevice => 'Vincular un dispositivo';

  @override
  String linkDeviceTitle(String name) {
    return '¿Vincular $name?';
  }

  @override
  String get linkDeviceBody =>
      'Podrá leer y enviar tus mensajes desde ahora hasta que lo desvincules. Vincula solo dispositivos de confianza.';

  @override
  String deviceLinked(String name) {
    return '$name está vinculado.';
  }

  @override
  String get unlink => 'Desvincular';

  @override
  String unlinkTitle(String name) {
    return '¿Desvincular $name?';
  }

  @override
  String get unlinkBody =>
      'Deja de recibir tus mensajes al instante y olvida todo lo que tenía.';

  @override
  String get tooManyDevices =>
      'Puedes vincular hasta 4 dispositivos. Desvincula uno primero.';

  @override
  String get errLinkExpired =>
      'Ese código ha caducado. Muestra uno nuevo en el dispositivo y escanéalo otra vez.';

  @override
  String get searchCountry => 'Busca un país o prefijo';

  @override
  String get chooseCountry => 'Elige tu país';

  @override
  String get phoneHintNational => 'Tu número, como lo marcarías en tu país';

  @override
  String smsGoesTo(String number, String country) {
    return 'Enviaremos el SMS a $number ($country).';
  }

  @override
  String get webPinCreateTitle => 'Elige un PIN para este navegador';

  @override
  String get webPinCreateBody =>
      'Siegel te lo pide cada vez que lo abres aquí. De 4 a 6 dígitos. Se queda en este navegador; si lo olvidas, vuelve a vincular el navegador.';

  @override
  String get webPinConfirm => 'Escríbelo otra vez';

  @override
  String get webPinMismatch => 'Los PIN no coinciden.';

  @override
  String get webPinEnterTitle => 'Escribe tu PIN';

  @override
  String webPinWrong(int left) {
    return 'PIN incorrecto. Quedan $left intentos antes de que Siegel olvide este navegador.';
  }

  @override
  String get webUnlock => 'Desbloquear';

  @override
  String get webForgotPin => '¿Olvidaste el PIN? Vincular de nuevo';

  @override
  String get webLinkTitle => 'Vincula este navegador';

  @override
  String get webLinkBody =>
      'En tu móvil, abre Siegel → Ajustes → Dispositivos vinculados → Vincular un dispositivo, y escanea este código.';

  @override
  String get webLinkWaiting => 'Esperando a tu móvil…';

  @override
  String get webExpired =>
      'Este navegador no se usó en 14 días, así que se desvinculó. Vuelve a vincularlo desde tu móvil.';

  @override
  String get unlinkThisBrowser => 'Desvincular este navegador';

  @override
  String get unlinkThisBrowserBody =>
      'Siegel olvida tus chats en este navegador. Tu móvil y tu cuenta siguen igual.';

  @override
  String get webPinLabel => 'PIN (de 4 a 6 dígitos)';

  @override
  String get errVideoCompress =>
      'No se pudo reducir este vídeo y pesa más de 100 MB. Recórtalo primero o envía uno más corto.';

  @override
  String get mostUsedStickers => 'Más usados';

  @override
  String get webNotifications => 'Notificaciones en este navegador';

  @override
  String get webNotificationsHelp =>
      'Con la pestaña cerrada, un aviso dice que hay un mensaje esperando. No puede decir de quién ni qué: nuestro servidor no lo sabe.';

  @override
  String get webNotificationsBlocked =>
      'El navegador no permitió las notificaciones de Siegel. Permítelas en la configuración del sitio y vuelve a intentarlo.';

  @override
  String get noChatOpen => 'Elige un chat a la izquierda.';

  @override
  String get camera => 'Cámara';

  @override
  String get viewOnce => 'Ver una vez';

  @override
  String get viewOncePhoto => 'Foto · ver una vez';

  @override
  String get viewOnceOpened => 'Abierta';

  @override
  String get viewOnceExpired => 'No se abrió a tiempo';

  @override
  String get viewOnceOpenHint => 'Se abre una vez y desaparece';

  @override
  String get viewOnceOnPhone =>
      'Las fotos de una sola vista solo se abren en tu móvil.';

  @override
  String get viewOnceHelp =>
      'Podrá abrirla una vez, en su móvil, con las capturas bloqueadas; después desaparece para los dos. Si no la abre en 14 días, también desaparece. Aun así, alguien podría fotografiar la pantalla con otra cámara.';

  @override
  String get errViewOnceGone =>
      'Esta foto de una sola vista no se puede volver a abrir.';

  @override
  String get gifs => 'GIFs';

  @override
  String get searchGifs => 'Buscar en GIPHY';

  @override
  String get noGifs => 'No se encontraron GIFs.';

  @override
  String get gifsUnavailable =>
      'Los GIFs no están disponibles ahora. Inténtalo más tarde.';

  @override
  String get gifsPrivacy =>
      'Las búsquedas pasan por el servidor de Siegel, así GIPHY nunca te ve. El GIF se envía cifrado de extremo a extremo, como una foto.';
}
