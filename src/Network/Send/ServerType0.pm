#########################################################################
#  OpenKore - Network subsystem
#  This module contains functions for sending messages to the server.
#
#  This software is open source, licensed under the GNU General Public
#  License, version 2.
#  Basically, this means that you're allowed to modify and distribute
#  this software. However, if you distribute modified versions, you MUST
#  also distribute the source code.
#  See http://www.gnu.org/licenses/gpl.html for the full license.
#########################################################################
# June 21 2007, this is the server type for:
# pRO (Philippines), except Sakray and Thor
# And many other servers.
# Servertype overview: http://wiki.openkore.com/index.php/ServerType
package Network::Send::ServerType0;

use strict;
use Time::HiRes qw(time);

use Misc qw(stripLanguageCode);
use Network::Send ();
use base qw(Network::Send);
use Plugins;
use Globals qw($accountID $sessionID $sessionID2 $accountSex $char $charID %config @chars $masterServer $syncSync);
use Log qw(debug);
use Translation qw(T TF);
use I18N qw(bytesToString stringToBytes);
use Utils;
use Utils::Exceptions;
use Utils::Rijndael;

# to test zealotus bug
#use Data::Dumper;


sub new {
	my ($class) = @_;
	my $self = $class->SUPER::new(@_);
	
	my %packets = (
		'0064' => ['master_login', 'V Z24 Z24 C', [qw(version username password master_version)]],
		'0065' => ['game_login', 'a4 a4 a4 v C', [qw(accountID sessionID sessionID2 userLevel accountSex)]],
		'0066' => ['char_login', 'C', [qw(slot)]],
		'0067' => ['char_create'], # TODO
		'0068' => ['char_delete'], # TODO
		'007D' => ['map_loaded'], # len 2
		'008C' => ['public_chat', 'x2 Z*', [qw(message)]],
		'0096' => ['private_message', 'x2 Z24 Z*', [qw(privMsgUser privMsg)]],
		'00B2' => ['restart', 'C', [qw(type)]],
		'0108' => ['party_chat', 'x2 Z*', [qw(message)]],
		'0149' => ['alignment', 'a4 C v', [qw(targetID type point)]],
		'014D' => ['guild_check'], # len 2
		'014F' => ['guild_info_request', 'V', [qw(type)]],
		'017E' => ['guild_chat', 'x2 Z*', [qw(message)]],
		'0187' => ['ban_check', 'a4', [qw(accountID)]],
		'018A' => ['quit_request', 'v', [qw(type)]],
		'0193' => ['actor_name_request', 'a4', [qw(ID)]],
		'01B2' => ['shop_open'], # TODO
		'012E' => ['shop_close'], # len 2
		'01DB' => ['secure_login_key_request'], # len 2
		'01DD' => ['master_login', 'V Z24 a16 C', [qw(version username password_md5 master_version)]],
		'01FA' => ['master_login', 'V Z24 a16 C C', [qw(version username password_md5 master_version clientInfo)]],
		'0204' => ['client_hash', 'a16', [qw(hash)]],
		'0208' => ['friend_response', 'a4 a4 V', [qw(friendAccountID friendCharID type)]],
		'021D' => ['less_effect'], # TODO
		'0232' => ['actor_move', 'a4 a3', [qw(ID coords)]],
		'0275' => ['game_login', 'a4 a4 a4 v C x16 v', [qw(accountID sessionID sessionID2 userLevel accountSex iAccountSID)]],
		'02B0' => ['master_login', 'V Z24 a24 C Z16 Z14 C', [qw(version username password_rijndael master_version ip mac isGravityID)]],
		'0369' => ['actor_name_request', 'a4', [qw(ID)]],
		'0437' => ['character_move','a3', [qw(coords)]],
		'0443' => ['skill_select', 'V v', [qw(why skillID)]],
		'0819' => ['buy_bulk_buyer', 'x2 x2 a4 a*', [qw(buyerID buyingStoreID zeny itemInfo)]],
		'0827' => ['char_delete2', 'a4', [qw(charID)]], # 6
		'082B' => ['char_delete2_cancel', 'a4', [qw(charID)]], # 6
		'08B8' => ['send_pin_password','a4 Z*', [qw(accountID pin)]],
		'08BA' => ['new_pin_password','a4 Z*', [qw(accountID pin)]],
		'0987' => ['master_login', 'V Z24 a32 C', [qw(version username password_md5_hex master_version)]],
		'09A1' => ['sync_received_characters'],
	);
	$self->{packet_list}{$_} = $packets{$_} for keys %packets;
	
	# # it would automatically use the first available if not set
	# my %handlers = qw(
	# 	master_login 0064
	# 	game_login 0065
	# 	map_login 0072
	# 	character_move 0085
	# );
	# $self->{packet_lut}{$_} = $handlers{$_} for keys %handlers;
	
	return $self;
}

sub version {
	return $masterServer->{version} || 1;
}

sub sendAddSkillPoint {
	my ($self, $skillID) = @_;
	my $msg = pack("C*", 0x12, 0x01) . pack("v*", $skillID);
	$self->sendToServer($msg);
}

sub sendAddStatusPoint {
	my ($self, $statusID) = @_;
	my $msg = pack("C*", 0xBB, 0) . pack("v*", $statusID) . pack("C*", 0x01);
	$self->sendToServer($msg);
}

sub sendAlignment {
	my ($self, $ID, $alignment) = @_;
	$self->sendToServer($self->reconstruct({
		switch => 'alignment',
		targetID => $ID,
		type => $alignment,
	}));
	debug "Sent Alignment: ".getHex($ID).", $alignment\n", "sendPacket", 2;
}

sub sendArrowCraft {
	my ($self, $index) = @_;
	my $msg = pack("C*", 0xAE, 0x01) . pack("v*", $index);
	$self->sendToServer($msg);
	debug "Sent Arrowmake: $index\n", "sendPacket", 2;
}

# 0x0089,7,actionrequest,2:6

sub sendAttackStop {
	my $self = shift;
	#my $msg = pack("C*", 0x18, 0x01);
	# Apparently this packet is wrong. The server disconnects us if we do this.
	# Sending a move command to the current position seems to be able to emulate
	# what this function is supposed to do.

	# Don't use this function, use Misc::stopAttack() instead!
	#sendMove ($char->{'pos_to'}{'x'}, $char->{'pos_to'}{'y'});
	#debug "Sent stop attack\n", "sendPacket";
}

sub sendAutoSpell {
	my ($self, $ID) = @_;
	my $msg = pack("C*", 0xce, 0x01, $ID, 0x00, 0x00, 0x00);
	$self->sendToServer($msg);
}

sub sendBanCheck {
	my ($self, $ID) = @_;
	$self->sendToServer($self->reconstruct({
		switch => 'ban_check',
		accountID => $ID,
	}));
	debug "Sent Account Ban Check Request : " . getHex($ID) . "\n", "sendPacket", 2;
}

=pod
sub sendBuy {
	my ($self, $ID, $amount) = @_;
	my $msg = pack("C*", 0xC8, 0x00, 0x08, 0x00) . pack("v*", $amount, $ID);
	$self->sendToServer($msg);
	debug "Sent buy: ".getHex($ID)."\n", "sendPacket", 2;
}
=cut
# 0x00c8,-1,npcbuylistsend,2:4
sub sendBuyBulk {
	my ($self, $r_array) = @_;
	my $msg = pack('v2', 0x00C8, 4+4*@{$r_array});
	for (my $i = 0; $i < @{$r_array}; $i++) {
		$msg .= pack('v2', $r_array->[$i]{amount}, $r_array->[$i]{itemID});
		debug "Sent bulk buy: $r_array->[$i]{itemID} x $r_array->[$i]{amount}\n", "d_sendPacket", 2;
	}
	$self->sendToServer($msg);
}

sub sendCardMerge {
	my ($self, $card_index, $item_index) = @_;
	my $msg = pack("C*", 0x7C, 0x01) . pack("v*", $card_index, $item_index);
	$self->sendToServer($msg);
	debug "Sent Card Merge: $card_index, $item_index\n", "sendPacket";
}

sub sendCardMergeRequest {
	my ($self, $card_index) = @_;
	my $msg = pack("C*", 0x7A, 0x01) . pack("v*", $card_index);
	$self->sendToServer($msg);
	debug "Sent Card Merge Request: $card_index\n", "sendPacket";
}

sub sendCartAdd {
	my ($self, $index, $amount) = @_;
	my $msg = pack("C*", 0x26, 0x01) . pack("v*", $index) . pack("V*", $amount);
	$self->sendToServer($msg);
	debug "Sent Cart Add: $index x $amount\n", "sendPacket", 2;
}

sub sendCartGet {
	my ($self, $index, $amount) = @_;
	my $msg = pack("C*", 0x27, 0x01) . pack("v*", $index) . pack("V*", $amount);
	$self->sendToServer($msg);
	debug "Sent Cart Get: $index x $amount\n", "sendPacket", 2;
}

sub sendCharCreate {
	my ($self, $slot, $name,
	    $str, $agi, $vit, $int, $dex, $luk,
		$hair_style, $hair_color) = @_;
	$hair_color ||= 1;
	$hair_style ||= 0;

	my $msg = pack("C*", 0x67, 0x00) .
		pack("a24", stringToBytes($name)) .
		pack("C*", $str, $agi, $vit, $int, $dex, $luk, $slot) .
		pack("v*", $hair_color, $hair_style);
	$self->sendToServer($msg);
}

sub sendCharDelete {
	my ($self, $charID, $email) = @_;
	my $msg = pack("C*", 0x68, 0x00) .
			$charID . pack("a40", stringToBytes($email));
	$self->sendToServer($msg);
}

sub sendCurrentDealCancel {
	my $msg = pack("C*", 0xED, 0x00);
	$_[0]->sendToServer($msg);
	debug "Sent Cancel Current Deal\n", "sendPacket", 2;
}

sub sendDeal {
	my ($self, $ID) = @_;
	my $msg = pack("C*", 0xE4, 0x00) . $ID;
	$_[0]->sendToServer($msg);
	debug "Sent Initiate Deal: ".getHex($ID)."\n", "sendPacket", 2;
}

sub sendDealReply {
	#Reply to a trade-request.
	# Type values:
	# 0: Char is too far
	# 1: Character does not exist
	# 2: Trade failed
	# 3: Accept
	# 4: Cancel
	# Weird enough, the client should only send 3/4
	# and the server is the one that can reply 0~2
	my ($self, $action) = @_;
	my $msg = pack('v C', 0x00E6, $action);
	$_[0]->sendToServer($msg);
	debug "Sent " . ($action == 3 ? "Accept": ($action == 4 ? "Cancel" : "action: " . $action)) . " Deal\n", "sendPacket", 2;
}

# TODO: legacy plugin support, remove later
sub sendDealAccept {
	$_[0]->sendDealReply(3);
	debug "Sent Cancel Deal\n", "sendPacket", 2;
}

# TODO: legacy plugin support, remove later
sub sendDealCancel {
	$_[0]->sendDealReply(4);
	debug "Sent Cancel Deal\n", "sendPacket", 2;
}

sub sendDealAddItem {
	my ($self, $index, $amount) = @_;
	my $msg = pack("C*", 0xE8, 0x00) . pack("v*", $index) . pack("V*",$amount);
	$_[0]->sendToServer($msg);
	debug "Sent Deal Add Item: $index, $amount\n", "sendPacket", 2;
}

sub sendDealFinalize {
	my $msg = pack("C*", 0xEB, 0x00);
	$_[0]->sendToServer($msg);
	debug "Sent Deal OK\n", "sendPacket", 2;
}

sub sendDealOK {
	my $msg = pack("C*", 0xEB, 0x00);
	$_[0]->sendToServer($msg);
	debug "Sent Deal OK\n", "sendPacket", 2;
}

sub sendDealTrade {
	my $msg = pack("C*", 0xEF, 0x00);
	$_[0]->sendToServer($msg);
	debug "Sent Deal Trade\n", "sendPacket", 2;
}

sub sendEmotion {
	my ($self, $ID) = @_;
	my $msg = pack("C*", 0xBF, 0x00).pack("C1",$ID);
	$self->sendToServer($msg);
	debug "Sent Emotion\n", "sendPacket", 2;
}

sub sendEquip {
	my ($self, $index, $type) = @_;
	my $msg = pack("C*", 0xA9, 0x00) . pack("v*", $index) .  pack("v*", $type);
	$self->sendToServer($msg);
	debug "Sent Equip: $index Type: $type\n" , 2;
}

sub sendProduceMix {
	my ($self, $ID,
		# nameIDs for added items such as Star Crumb or Flame Heart
		$item1, $item2, $item3) = @_;

	my $msg = pack("v5", 0x018E, $ID, $item1, $item2, $item3);
	$self->sendToServer($msg);
	debug "Sent Forge, Produce Item: $ID\n" , 2;
}

sub sendNPCBuySellList { # type:0 get store list, type:1 get sell list
	my ($self, $ID, $type) = @_;
	my $msg = pack('v a4 C', 0x00C5, $ID , $type);
	$self->sendToServer($msg);
	debug "Sent get ".($type ? "buy" : "sell")." list to NPC: ".getHex($ID)."\n", "sendPacket", 2;
}

sub sendGMSummon {
	my ($self, $playerName) = @_;
	my $packet = pack("C*", 0xBD, 0x01) . pack("a24", stringToBytes($playerName));
	$self->sendToServer($packet);
}

sub sendGuildJoin {
	my ($self, $ID, $flag) = @_;
	my $msg = pack("C*", 0x6B, 0x01).$ID.pack("V1", $flag);
	$self->sendToServer($msg);
	debug "Sent Join Guild : ".getHex($ID).", $flag\n", "sendPacket";
}

sub sendHomunculusAttack {
	my $self = shift;
	my $homunID = shift;
	my $targetID = shift;
	my $flag = shift;
	my $msg = pack("C*", 0x33, 0x02) . $homunID . $targetID . pack("C1", $flag);
	$self->sendToServer($msg);
	debug "Sent Homunculus attack: ".getHex($targetID)."\n", "sendPacket", 2;
}

sub sendHomunculusStandBy {
	my $self = shift;
	my $homunID = shift;
	my $msg = pack("C*", 0x34, 0x02) . $homunID;
	$self->sendToServer($msg);
	debug "Sent Homunculus standby\n", "sendPacket", 2;
}

sub sendHomunculusName {
	my $self = shift;
	my $name = shift;
	my $msg = pack("v1 a24", 0x0231, stringToBytes($name));
	$self->sendToServer($msg);
	debug "Sent Homunculus Rename: $name\n", "sendPacket", 2;
}

sub sendIdentify {
	my $self = shift;
	my $index = shift;
	my $msg = pack("C*", 0x78, 0x01) . pack("v*", $index);
	$self->sendToServer($msg);
	debug "Sent Identify: $index\n", "sendPacket", 2;
}

sub sendIgnore {
	my $self = shift;
	my $name = shift;
	my $flag = shift;

	my $binName = stringToBytes($name);
	$binName = substr($binName, 0, 24) if (length($binName) > 24);
	$binName = $binName . chr(0) x (24 - length($binName));
	my $msg = pack("C*", 0xCF, 0x00) . $binName . pack("C*", $flag);

	$self->sendToServer($msg);
	debug "Sent Ignore: $name, $flag\n", "sendPacket", 2;
}

sub sendIgnoreAll {
	my $self = shift;
	my $flag = shift;
	my $msg = pack("C*", 0xD0, 0x00).pack("C*", $flag);
	$self->sendToServer($msg);
	debug "Sent Ignore All: $flag\n", "sendPacket", 2;
}

sub sendIgnoreListGet {
	my $self = shift;
	my $flag = shift;
	my $msg = pack("C*", 0xD3, 0x00);
	$self->sendToServer($msg);
	debug "Sent get Ignore List: $flag\n", "sendPacket", 2;
}

sub sendItemUse {
	my ($self, $ID, $targetID) = @_;
	my $msg;
	
	$msg = pack("C*", 0xA7, 0x00).pack("v*",$ID) .
		$targetID;

	$self->sendToServer($msg);
	debug "Item Use: $ID\n", "sendPacket", 2;
}

sub sendMemo {
	my $self = shift;
	my $msg = pack("C*", 0x1D, 0x01);
	$self->sendToServer($msg);
	debug "Sent Memo\n", "sendPacket", 2;
}

sub sendOpenShop {
	my ($self, $title, $items) = @_;

	my $length = 0x55 + 0x08 * @{$items};
	my $msg = pack("C*", 0xB2, 0x01).
		pack("v*", $length).
		pack("a80", stringToBytes($title)).
		pack("C*", 0x01);

	foreach my $item (@{$items}) {
		$msg .= pack("v1", $item->{index}).
			pack("v1", $item->{amount}).
			pack("V1", $item->{price});
	}

	$self->sendToServer($msg);
}

sub sendPartyJoin {
	my $self = shift;
	my $ID = shift;
	my $flag = shift;
	my $msg = pack("C*", 0xFF, 0x00).$ID.pack("V", $flag);
	$self->sendToServer($msg);
	debug "Sent Join Party: ".getHex($ID).", $flag\n", "sendPacket", 2;
}

sub sendPartyJoinRequest {
	my $self = shift;
	my $ID = shift;
	my $msg = pack("C*", 0xFC, 0x00).$ID;
	$self->sendToServer($msg);
	debug "Sent Request Join Party: ".getHex($ID)."\n", "sendPacket", 2;
}

sub _binName {
	my $name = shift;
	
	$name = stringToBytes ($name);
	$name = substr ($name, 0, 24) if 24 < length $name;
	$name .= "\x00" x (24 - length $name);
	return $name;
}

sub sendPartyJoinRequestByName {
	my $self = shift;
	my $name = shift;
	my $msg = pack ('C*', 0xc4, 0x02) . _binName ($name);
	$self->sendToServer($msg);
	debug "Sent Request Join Party (by name): $name\n", "sendPacket", 2;
}

sub sendPartyJoinRequestByNameReply {
	my ($self, $accountID, $flag) = @_;
	my $msg = pack('v a4 C', 0x02C7, $accountID, $flag);
	$self->sendToServer($msg);
	debug "Sent reply Party Invite.\n", "sendPacket", 2;
}

sub sendPartyKick {
	my $self = shift;
	my $ID = shift;
	my $name = shift;
	my $msg = pack("C*", 0x03, 0x01) . $ID . _binName ($name);
	$self->sendToServer($msg);
	debug "Sent Kick Party: ".getHex($ID).", $name\n", "sendPacket", 2;
}

sub sendPartyLeave {
	my $self = shift;
	my $msg = pack("C*", 0x00, 0x01);
	$self->sendToServer($msg);
	debug "Sent Leave Party\n", "sendPacket", 2;
}

sub sendPartyOrganize {
	my $self = shift;
	my $name = shift;
	my $share1 = shift || 1;
	my $share2 = shift || 1;

	my $binName = stringToBytes($name);
	$binName = substr($binName, 0, 24) if (length($binName) > 24);
	$binName .= chr(0) x (24 - length($binName));
	#my $msg = pack("C*", 0xF9, 0x00) . $binName;
	# I think this is obsolete - which serverTypes still support this packet anyway?
	# FIXME: what are shared with $share1 and $share2? experience? item? vice-versa?
	
	my $msg = pack("C*", 0xE8, 0x01) . $binName . pack("C*", $share1, $share2);

	$self->sendToServer($msg);
	debug "Sent Organize Party: $name\n", "sendPacket", 2;
}

# legacy plugin support, remove later
sub sendPartyShareEXP {
	my ($self, $exp) = @_;
	$self->sendPartyOption($exp, 0);
}

# 0x0102,6,partychangeoption,2:4
# note: item share changing seems disabled in newest clients
sub sendPartyOption {
	my ($self, $exp, $itemPickup, $itemDivision) = @_;
	
	$self->sendToServer($self->reconstruct({
		switch => 'party_setting',
		exp => $exp,
		itemPickup => $itemPickup,
		itemDivision => $itemDivision,
	}));
	debug "Sent Party Option\n", "sendPacket", 2;
}

sub sendPetCapture {
	my ($self, $monID) = @_;
	my $msg = pack('v a4', 0x019F, $monID);
	$self->sendToServer($msg);
	debug "Sent pet capture: ".getHex($monID)."\n", "sendPacket", 2;
}

# 0x01a1,3,petmenu,2
sub sendPetMenu {
	my ($self, $type) = @_; # 0:info, 1:feed, 2:performance, 3:to egg, 4:uneq item
	my $msg = pack('v C', 0x01A1, $type);
	$self->sendToServer($msg);
	debug "Sent Pet Menu\n", "sendPacket", 2;
}

sub sendPetHatch {
	my ($self, $index) = @_;
	my $msg = pack('v2', 0x01A7, $index);
	$self->sendToServer($msg);
	debug "Sent Incubator hatch: $index\n", "sendPacket", 2;
}

sub sendPetName {
	my ($self, $name) = @_;
	my $msg = pack('v a24', 0x01A5, stringToBytes($name));
	$self->sendToServer($msg);
	debug "Sent Pet Rename: $name\n", "sendPacket", 2;
}

# 0x01af,4,changecart,2
sub sendChangeCart { # lvl: 1, 2, 3, 4, 5
	my ($self, $lvl) = @_;
	my $msg = pack('v2', 0x01AF, $lvl);
	$self->sendToServer($msg);
	debug "Sent Cart Change to : $lvl\n", "sendPacket", 2;
}

sub sendPreLoginCode {
	# no server actually needs this, but we might need it in the future?
	my $self = shift;
	my $type = shift;
	my $msg;
	if ($type == 1) {
		$msg = pack("C*", 0x04, 0x02, 0x82, 0xD1, 0x2C, 0x91, 0x4F, 0x5A, 0xD4, 0x8F, 0xD9, 0x6F, 0xCF, 0x7E, 0xF4, 0xCC, 0x49, 0x2D);
	}
	$self->sendToServer($msg);
	debug "Sent pre-login packet $type\n", "sendPacket", 2;
}

sub sendRaw {
	my $self = shift;
	my $raw = shift;
	my @raw;
	my $msg;
	@raw = split / /, $raw;
	foreach (@raw) {
		$msg .= pack("C", hex($_));
	}
	$self->sendToServer($msg);
	debug "Sent Raw Packet: @raw\n", "sendPacket", 2;
}

sub sendRequestMakingHomunculus {
	# WARNING: If you don't really know, what are you doing - don't touch this
	my ($self, $make_homun) = @_;
	
	my $skill = new Skill (idn => 241);
	
	if (
		Actor::Item::get (997) && Actor::Item::get (998) && Actor::Item::get (999)
		&& ($char->getSkillLevel ($skill) > 0)
	) {
		my $msg = pack ('v C', 0x01CA, $make_homun);
		$self->sendToServer($msg);
		debug "Sent RequestMakingHomunculus\n", "sendPacket", 2;
	}
}

sub sendRemoveAttachments {
	# remove peco, falcon, cart
	my $msg = pack("C*", 0x2A, 0x01);
	$_[0]->sendToServer($msg);
	debug "Sent remove attachments\n", "sendPacket", 2;
}

sub sendRepairItem {
	my ($self, $args) = @_;
	my $msg = pack("C2 v2 V2 C1", 0xFD, 0x01, $args->{index}, $args->{nameID}, $args->{status}, $args->{status2}, $args->{listID});
	$self->sendToServer($msg);
	debug ("Sent repair item: ".$args->{index}."\n", "sendPacket", 2);
}

sub sendSell {
	my $self = shift;
	my $index = shift;
	my $amount = shift;
	my $msg = pack("C*", 0xC9, 0x00, 0x08, 0x00) . pack("v*", $index, $amount);
	$self->sendToServer($msg);
	debug "Sent sell: $index x $amount\n", "sendPacket", 2;
}

sub sendSellBulk {
	my $self = shift;
	my $r_array = shift;
	my $sellMsg = "";

	for (my $i = 0; $i < @{$r_array}; $i++) {
		$sellMsg .= pack("v*", $r_array->[$i]{index}, $r_array->[$i]{amount});
		debug "Sent bulk sell: $r_array->[$i]{index} x $r_array->[$i]{amount}\n", "d_sendPacket", 2;
	}

	my $msg = pack("C*", 0xC9, 0x00) . pack("v*", length($sellMsg) + 4) . $sellMsg;
	$self->sendToServer($msg);
}

sub sendStorageAddFromCart {
	my $self = shift;
	my $index = shift;
	my $amount = shift;
	my $msg;
	$msg = pack("C*", 0x29, 0x01) . pack("v*", $index) . pack("V*", $amount);
	$self->sendToServer($msg);
	debug "Sent Storage Add From Cart: $index x $amount\n", "sendPacket", 2;
}

sub sendStorageClose {
	my ($self) = @_;
	my $msg;
	if (($self->{serverType} == 3) || ($self->{serverType} == 5) || ($self->{serverType} == 9) || ($self->{serverType} == 15)) {
		$msg = pack("C*", 0x93, 0x01);
	} elsif ($self->{serverType} == 12) {
		$msg = pack("C*", 0x72, 0x00);
	} elsif ($self->{serverType} == 14) {
		$msg = pack("C*", 0x16, 0x01);
	} else {
		$msg = pack("C*", 0xF7, 0x00);
	}

	$self->sendToServer($msg);
	debug "Sent Storage Done\n", "sendPacket", 2;
}

sub sendStorageGetToCart {
	my $self = shift;
	my $index = shift;
	my $amount = shift;
	my $msg;
	$msg = pack("C*", 0x28, 0x01) . pack("v*", $index) . pack("V*", $amount);
	$self->sendToServer($msg);
	debug "Sent Storage Get From Cart: $index x $amount\n", "sendPacket", 2;
}

sub sendStoragePassword {
	my $self = shift;
	# 16 byte packed hex data
	my $pass = shift;
	# 2 = set password ?
	# 3 = give password ?
	my $type = shift;
	my $msg;
	if ($type == 3) {
		$msg = pack("C C v", 0x3B, 0x02, $type).$pass.pack("H*", "EC62E539BB6BBC811A60C06FACCB7EC8");
	} elsif ($type == 2) {
		$msg = pack("C C v", 0x3B, 0x02, $type).pack("H*", "EC62E539BB6BBC811A60C06FACCB7EC8").$pass;
	} else {
		ArgumentException->throw("The 'type' argument has invalid value ($type).");
	}
	$self->sendToServer($msg);
}

sub sendSuperNoviceDoriDori {
	my $msg = pack("C*", 0xE7, 0x01);
	$_[0]->sendToServer($msg);
	debug "Sent Super Novice dori dori\n", "sendPacket", 2;
}

# TODO: is this the sn mental ingame triggered trough the poem?
sub sendSuperNoviceExplosion {
	my $msg = pack("C*", 0xED, 0x01);
	$_[0]->sendToServer($msg);
	debug "Sent Super Novice Explosion\n", "sendPacket", 2;
}

sub sendTalk {
	my $self = shift;
	my $ID = shift;
	my $msg = pack("C*", 0x90, 0x00) . $ID . pack("C*",0x01);
	$self->sendToServer($msg);
	debug "Sent talk: ".getHex($ID)."\n", "sendPacket", 2;
}

sub sendTalkCancel {
	my $self = shift;
	my $ID = shift;
	my $msg = pack("C*", 0x46, 0x01) . $ID;
	$self->sendToServer($msg);
	debug "Sent talk cancel: ".getHex($ID)."\n", "sendPacket", 2;
}

sub sendTalkContinue {
	my $self = shift;
	my $ID = shift;
	my $msg = pack("C*", 0xB9, 0x00) . $ID;
	$self->sendToServer($msg);
	debug "Sent talk continue: ".getHex($ID)."\n", "sendPacket", 2;
}

sub sendTalkResponse {
	my $self = shift;
	my $ID = shift;
	my $response = shift;
	my $msg = pack("C*", 0xB8, 0x00) . $ID. pack("C1",$response);
	$self->sendToServer($msg);
	debug "Sent talk respond: ".getHex($ID).", $response\n", "sendPacket", 2;
}

sub sendTalkNumber {
	my $self = shift;
	my $ID = shift;
	my $number = shift;
	my $msg = pack("C*", 0x43, 0x01) . $ID .
			pack("V1", $number);
	$self->sendToServer($msg);
	debug "Sent talk number: ".getHex($ID).", $number\n", "sendPacket", 2;
}

sub sendTalkText {
	my $self = shift;
	my $ID = shift;
	my $input = stringToBytes(shift);
	my $msg = pack("C*", 0xD5, 0x01) . pack("v*", length($input)+length($ID)+5) . $ID . $input . chr(0);
	$self->sendToServer($msg);
	debug "Sent talk text: ".getHex($ID).", $input\n", "sendPacket", 2;
}

# 0x011b,20,useskillmap,2:4
sub sendWarpTele { # type: 26=tele, 27=warp
	my ($self, $skillID, $map) = @_;
	my $msg = pack('v2 Z16', 0x011B, $skillID, stringToBytes($map));
	$self->sendToServer($msg);
	debug "Sent ". ($skillID == 26 ? "Teleport" : "Open Warp") . "\n", "sendPacket", 2
}

sub sendUnequip {
	my $self = shift;
	my $index = shift;
	my $msg = pack("v", 0x00AB) . pack("v*", $index);
	$self->sendToServer($msg);
	debug "Sent Unequip: $index\n", "sendPacket", 2;
}

sub sendWho {
	my $self = shift;
	my $msg = pack("v", 0x00C1);
	$self->sendToServer($msg);
	debug "Sent Who\n", "sendPacket", 2;
}

sub SendAdoptReply {
	my ($self, $parentID1, $parentID2, $result) = @_;
	my $msg = pack("v V3", 0x01F7, $parentID1, $parentID2, $result);
	$self->sendToServer($msg);
	debug "Sent Adoption Reply.\n", "sendPacket", 2;
}

sub SendAdoptRequest {
	my ($self, $ID) = @_;
	my $msg = pack("v V", 0x01F9, $ID);
	$self->sendToServer($msg);
	debug "Sent Adoption Request.\n", "sendPacket", 2;
}

sub sendCashShopBuy {
	my ($self, $ID, $amount, $points) = @_;
	my $msg = pack("v v2 V", 0x0288, $ID, $amount, $points);
	$self->sendToServer($msg);
	debug "Sent My Sell Stop.\n", "sendPacket", 2;
}

sub sendAutoRevive {
	my ($self, $ID, $amount, $points) = @_;
	my $msg = pack("v", 0x0292);
	$self->sendToServer($msg);
	debug "Sent Auto Revive.\n", "sendPacket", 2;
}

sub sendMercenaryCommand {
	my ($self, $command) = @_;
	
	# 0x0 => COMMAND_REQ_NONE
	# 0x1 => COMMAND_REQ_PROPERTY
	# 0x2 => COMMAND_REQ_DELETE
	
	my $msg = pack ('v C', 0x029F, $command);
	$self->sendToServer($msg);
	debug "Sent Mercenary Command $command", "sendPacket", 2;
}

sub sendMessageIDEncryptionInitialized {
	my $self = shift;
	my $msg = pack("v", 0x02AF);
	$self->sendToServer($msg);
	debug "Sent Message ID Encryption Initialized\n", "sendPacket", 2;
}

# has the same effects as rightclicking in quest window
sub sendQuestState {
	my ($self, $questID, $state) = @_;
	my $msg = pack("v V C", 0x02B6, $questID, $state);
	$self->sendToServer($msg);
	debug "Sent Quest State.\n", "sendPacket", 2;
}

sub sendShowEquipPlayer {
	my ($self, $ID) = @_;
	my $msg = pack("v a4", 0x02D6, $ID);
	$self->sendToServer($msg);
	debug "Sent Show Equip Player.\n", "sendPacket", 2;
}

sub sendShowEquipTickbox {
	my ($self, $flag) = @_;
	my $msg = pack("v V2", 0x02D8, 0, $flag);
	$self->sendToServer($msg);
	debug "Sent Show Equip Tickbox: flag.\n", "sendPacket", 2;
}

sub sendBattlegroundChat {
	my ($self, $message) = @_;
	$message = "|00$message" if ($config{chatLangCode} && $config{chatLangCode} ne "none");
	my $msg = pack("v2 Z*", 0x02DB, length($message)+4, stringToBytes($message));
	$self->sendToServer($msg);
	debug "Sent Battleground chat.\n", "sendPacket", 2;
}

sub sendCooking {
	my ($self, $type, $nameID) = @_;
	my $msg = pack("v3", 0x025B, $type, $nameID);
	$self->sendToServer($msg);
	debug "Sent Cooking.\n", "sendPacket", 2;
}

sub sendWeaponRefine {
	my ($self, $index) = @_;
	my $msg = pack("v V", 0x0222, $index);
	$self->sendToServer($msg);
	debug "Sent Weapon Refine.\n", "sendPacket", 2;
}

sub sendProgress {
	my ($self) = @_;
	my $msg = pack("C*", 0xf1, 0x02);
	$self->sendToServer($msg);
	debug "Sent Progress Bar Finish\n", "sendPacket", 2;
}

# 0x0204,18

1;