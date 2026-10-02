import 'dart:convert';

class BroadcastChannel {
  String id;
  String name;
  double gain;
  double pan;
  bool muted;
  bool solo;
  bool noiseGate;
  bool compressor;
  bool eq;

  BroadcastChannel({required this.id, required this.name, this.gain = 0.0, this.pan = 0.0, this.muted = false, this.solo = false, this.noiseGate = true, this.compressor = true, this.eq = true});
  Map<String,dynamic> toJson()=>{'id':id,'name':name,'gain':gain,'pan':pan,'muted':muted,'solo':solo,'noiseGate':noiseGate,'compressor':compressor,'eq':eq};
  factory BroadcastChannel.fromJson(Map<String,dynamic> j)=>BroadcastChannel(id:j['id']??'',name:j['name']??'',gain:(j['gain'] as num?)?.toDouble()??0,pan:(j['pan'] as num?)?.toDouble()??0,muted:j['muted']??false,solo:j['solo']??false,noiseGate:j['noiseGate']??true,compressor:j['compressor']??true,eq:j['eq']??true);
}

class AutoDjSettings {
  bool enabled;
  bool shuffle;
  bool repeatProtection;
  bool artistSeparation;
  bool categoryRotation;
  bool crossfade;
  int crossfadeSeconds;
  int songsBetweenAds;
  bool insertStationId;
  AutoDjSettings({this.enabled=false,this.shuffle=true,this.repeatProtection=true,this.artistSeparation=true,this.categoryRotation=true,this.crossfade=true,this.crossfadeSeconds=4,this.songsBetweenAds=4,this.insertStationId=true});
  Map<String,dynamic> toJson()=>{'enabled':enabled,'shuffle':shuffle,'repeatProtection':repeatProtection,'artistSeparation':artistSeparation,'categoryRotation':categoryRotation,'crossfade':crossfade,'crossfadeSeconds':crossfadeSeconds,'songsBetweenAds':songsBetweenAds,'insertStationId':insertStationId};
  factory AutoDjSettings.fromJson(Map<String,dynamic> j)=>AutoDjSettings(enabled:j['enabled']??false,shuffle:j['shuffle']??true,repeatProtection:j['repeatProtection']??true,artistSeparation:j['artistSeparation']??true,categoryRotation:j['categoryRotation']??true,crossfade:j['crossfade']??true,crossfadeSeconds:(j['crossfadeSeconds'] as num?)?.toInt()??4,songsBetweenAds:(j['songsBetweenAds'] as num?)?.toInt()??4,insertStationId:j['insertStationId']??true);
}

class StationAd {
  String id;
  String name;
  String filePath;
  int durationSeconds;
  bool enabled;
  StationAd({required this.id,required this.name,required this.filePath,this.durationSeconds=30,this.enabled=true});
  Map<String,dynamic> toJson()=>{'id':id,'name':name,'filePath':filePath,'durationSeconds':durationSeconds,'enabled':enabled};
  factory StationAd.fromJson(Map<String,dynamic> j)=>StationAd(id:j['id']??'',name:j['name']??'',filePath:j['filePath']??'',durationSeconds:(j['durationSeconds'] as num?)?.toInt()??30,enabled:j['enabled']??true);
}

class PodcastShow {
  String id;
  String name;
  String description;
  String artworkPath;
  String category;
  String language;
  String website;
  List<String> hostIds;
  PodcastShow({required this.id,required this.name,this.description='',this.artworkPath='',this.category='Society & Culture',this.language='en',this.website='',List<String>? hostIds}):hostIds=hostIds??[];
  Map<String,dynamic> toJson()=>{'id':id,'name':name,'description':description,'artworkPath':artworkPath,'category':category,'language':language,'website':website,'hostIds':hostIds};
  factory PodcastShow.fromJson(Map<String,dynamic> j)=>PodcastShow(id:j['id']??'',name:j['name']??'',description:j['description']??'',artworkPath:j['artworkPath']??'',category:j['category']??'Society & Culture',language:j['language']??'en',website:j['website']??'',hostIds:List<String>.from(j['hostIds']??const[]));
}

class PodcastHost {
  String id;
  String name;
  String bio;
  String email;
  PodcastHost({required this.id,required this.name,this.bio='',this.email=''});
  Map<String,dynamic> toJson()=>{'id':id,'name':name,'bio':bio,'email':email};
  factory PodcastHost.fromJson(Map<String,dynamic> j)=>PodcastHost(id:j['id']??'',name:j['name']??'',bio:j['bio']??'',email:j['email']??'');
}

class PodcastEditOperation {
  final String type;
  final double start;
  final double end;
  final String? assetPath;
  final String? label;
  const PodcastEditOperation({required this.type,required this.start,this.end=0,this.assetPath,this.label});
  Map<String,dynamic> toJson()=>{'type':type,'start':start,'end':end,'assetPath':assetPath,'label':label};
  factory PodcastEditOperation.fromJson(Map<String,dynamic> j)=>PodcastEditOperation(type:j['type']??'',start:(j['start'] as num?)?.toDouble()??0,end:(j['end'] as num?)?.toDouble()??0,assetPath:j['assetPath'],label:j['label']);
}

String encodeList<T>(List<T> items, Map<String,dynamic> Function(T) mapper)=>jsonEncode(items.map(mapper).toList());
