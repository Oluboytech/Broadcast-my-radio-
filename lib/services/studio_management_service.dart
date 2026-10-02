import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/studio_models.dart';

class StudioManagementService {
  static const _channels='pro_mixer_channels';
  static const _ads='station_ads';
  static const _shows='podcast_shows';
  static const _hosts='podcast_hosts';
  static const _autodj='auto_dj_settings';

  Future<List<BroadcastChannel>> loadChannels() async { final p=await SharedPreferences.getInstance(); final raw=p.getString(_channels); if(raw==null)return [BroadcastChannel(id:'mic',name:'Microphone'),BroadcastChannel(id:'music',name:'Music / Playlist'),BroadcastChannel(id:'cart',name:'Cart / Jingle'),BroadcastChannel(id:'remote',name:'Remote Guest')]; try{return (jsonDecode(raw) as List).map((e)=>BroadcastChannel.fromJson(Map<String,dynamic>.from(e))).toList();}catch(_){return [];} }
  Future<void> saveChannels(List<BroadcastChannel> v) async {final p=await SharedPreferences.getInstance(); await p.setString(_channels,jsonEncode(v.map((e)=>e.toJson()).toList()));}
  Future<List<StationAd>> loadAds() async {final p=await SharedPreferences.getInstance(); final raw=p.getString(_ads); if(raw==null)return []; try{return (jsonDecode(raw) as List).map((e)=>StationAd.fromJson(Map<String,dynamic>.from(e))).toList();}catch(_){return [];}}
  Future<void> saveAds(List<StationAd> v) async {final p=await SharedPreferences.getInstance();await p.setString(_ads,jsonEncode(v.map((e)=>e.toJson()).toList()));}
  Future<List<PodcastShow>> loadShows() async {final p=await SharedPreferences.getInstance();final raw=p.getString(_shows);if(raw==null)return [PodcastShow(id:'default',name:'My Podcast')];try{return (jsonDecode(raw) as List).map((e)=>PodcastShow.fromJson(Map<String,dynamic>.from(e))).toList();}catch(_){return [];}}
  Future<void> saveShows(List<PodcastShow> v) async {final p=await SharedPreferences.getInstance();await p.setString(_shows,jsonEncode(v.map((e)=>e.toJson()).toList()));}
  Future<List<PodcastHost>> loadHosts() async {final p=await SharedPreferences.getInstance();final raw=p.getString(_hosts);if(raw==null)return [];try{return (jsonDecode(raw) as List).map((e)=>PodcastHost.fromJson(Map<String,dynamic>.from(e))).toList();}catch(_){return [];}}
  Future<void> saveHosts(List<PodcastHost> v) async {final p=await SharedPreferences.getInstance();await p.setString(_hosts,jsonEncode(v.map((e)=>e.toJson()).toList()));}
  Future<AutoDjSettings> loadAutoDj() async {final p=await SharedPreferences.getInstance();final raw=p.getString(_autodj);if(raw==null)return AutoDjSettings();try{return AutoDjSettings.fromJson(jsonDecode(raw));}catch(_){return AutoDjSettings();}}
  Future<void> saveAutoDj(AutoDjSettings v) async {final p=await SharedPreferences.getInstance();await p.setString(_autodj,jsonEncode(v.toJson()));}
}
