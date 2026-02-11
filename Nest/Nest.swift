//
//  Nest
//  cliapis
//
//  Created by Cliapis on 20/12/2016.
//  Copyright © 2016 Cliapis. All rights reserved.
//

import Foundation
import Dispatch

public enum ExpirationPolicy: RawRepresentable {
    
    case short
    case medium
    case long
    case max
    case never
    case custom(TimeInterval)
    
    var interval: TimeInterval {
        
        switch self {
        case .short:                    return 60.0
        case .medium:                   return 300.0
        case .long:                     return 600.0
        case .max:                      return 900.0
        case .never:                    return Date.distantFuture.timeIntervalSinceNow
        case .custom(let interval):     return interval
        }
    }
    
    public var rawValue: String {
        
        switch self {
        case .short:                    return "short"
        case .medium:                   return "medium"
        case .long:                     return "long"
        case .max:                      return "max"
        case .never:                    return "never"
        case .custom(let interval):     return "custom:\(interval)"
        }
    }
    
    
    public init?(rawValue: String) {
        
        switch rawValue {
            
        case "short":   self =  .short
        case "medium":  self =  .medium
        case "long":    self =  .long
        case "max":     self =  .max
    	case "never":   self =  .never
        default:
            
            guard rawValue.hasPrefix("custom:"),
                let interval = TimeInterval(String(rawValue[rawValue.index(rawValue.startIndex, offsetBy: 7)...])) else {  return nil }
            
            self = .custom(interval)
        }
    }
}


public enum PersistancePolicy: RawRepresentable {
    
    case disabled
    case mirror
    case short
    case medium
    case long
    
    var interval: TimeInterval {
        
        switch self {
        case .disabled:                 return 0
        case .mirror:                   return 0
        case .short:                    return 86400
        case .medium:                   return 259200
        case .long:                     return 864000
        }
    }
    
    public var rawValue: String {
        
        switch self {
        case .disabled:                 return "disabled"
        case .mirror:                   return "mirror"
        case .short:                    return "short"
        case .medium:                   return "medium"
        case .long:                     return "long"
        }
    }
    
    
    public init?(rawValue: String) {
        
        switch rawValue {
        case "disabled":    self = .disabled
        case "mirror" :     self = .mirror
        case "short" :      self = .short
        case "medium" :     self = .medium
        case "long" :       self = .long
        default:            return nil
            
        }
    }
}


// MARK:- CacheItem

fileprivate class Seed: NSObject, NSSecureCoding {

    static var supportsSecureCoding: Bool { return true }

    var key: String

    var _object: Any?
    var object: Any? {

        if let object = _object { return object }

        if let filename = filename {

            guard let documentsURL = Nest.documentsURL() else { return  _object }
            let fileURL = documentsURL.appendingPathComponent(filename)

            if let data = try? Data(contentsOf: fileURL),
               let object = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) {

                _object = object
                setExpirationDates()
            }
        }

        return _object
    }
    
    var expirationPolicy: ExpirationPolicy
    var persistancePolicy: PersistancePolicy
    
    var expirationDate: Date?
    var persistanceExpirationDate: Date?
    var filename: String?
    
    init(key: String, object: Any?, expirationPolicy: ExpirationPolicy, persistancePolicy: PersistancePolicy, filename: String?) {
        
        self.key = key
        self._object = object
        self.expirationPolicy = expirationPolicy
        self.persistancePolicy = persistancePolicy
        self.filename = filename
        
        expirationDate = Date().addingTimeInterval(expirationPolicy.interval)
        
        if persistancePolicy.interval != 0 {
            
            persistanceExpirationDate = Date().addingTimeInterval(persistancePolicy.interval)
        }
    }
    
    
    // MARK: NSCoding Protocol
    
    required init?(coder aDecoder: NSCoder) {

        guard let key = aDecoder.decodeObject(of: NSString.self, forKey: "key") as String?,
            let rawExpirationPolicy = aDecoder.decodeObject(of: NSString.self, forKey: "expirationPolicy") as String?,
            let expirationPolicy = ExpirationPolicy(rawValue: rawExpirationPolicy),
            let rawPersistancePolicy = aDecoder.decodeObject(of: NSString.self, forKey: "persistancePolicy") as String?,
            let persistancePolicy = PersistancePolicy(rawValue: rawPersistancePolicy)
            else { return nil }

        self.key = key
        self.expirationPolicy = expirationPolicy
        self.persistancePolicy = persistancePolicy

        if persistancePolicy.interval != 0 {

            persistanceExpirationDate = Date().addingTimeInterval(persistancePolicy.interval)
        }

        if let filename = aDecoder.decodeObject(of: NSString.self, forKey: "filename") as String? {

            self.filename = filename
        }
    }
    
    
    internal func encode(with aCoder: NSCoder) {
        
        aCoder.encode(key, forKey: "key")
        aCoder.encode(expirationPolicy.rawValue, forKey: "expirationPolicy")
        aCoder.encode(persistancePolicy.rawValue, forKey: "persistancePolicy")
        if let filename = filename {
        
            aCoder.encode(filename, forKey: "filename")
        }
    }
    
    
    func invalidateObject() {
        
        _object = nil
    }
    
    
    // MARK: Expiration Policy Setup
    
    fileprivate func setExpirationDates() {
        
        expirationDate = Date().addingTimeInterval(expirationPolicy.interval)
        
        if persistancePolicy.interval != 0 {
            
            persistanceExpirationDate = Date().addingTimeInterval(persistancePolicy.interval)
        }
    }
}



// MARK:- Cache

fileprivate let indexFilename = "NestContents"

open class Nest: NSObject {
    
    public static let shared = Nest()
    fileprivate var storage: [String: Seed] = [:]
    
    fileprivate let queue = DispatchQueue(label: "com.nest.writeQueue")

    fileprivate var storageCopy: [String: Seed] {
        return queue.sync { storage }
    }

    subscript (key: String) -> Any? {

        let _storage = storageCopy
        guard let object = _storage[key]?.object else {

            syncRemove(itemWith: key)
            return nil
        }

        return object
    }
    
    
    
    // MARK: Init
    
    override init() {
        
        super.init()
        load()
    }
    
    
    // MARK: Add
    
    open func add(item: Any, withKey key: String, expirationPolicy policy: ExpirationPolicy, andPersistancePolicy persistPolicy: PersistancePolicy = .disabled) {
        
        var filename: String? = nil
        
        var resolvedPersistPolicy = persistPolicy
        
        if persistPolicy != .disabled, item is NSCopying, let documentsURL = Nest.documentsURL() {
            
            let uuid = UUID().uuidString
            filename = uuid
            let fileURL = documentsURL.appendingPathComponent(uuid)
            
            do {
                let data = try NSKeyedArchiver.archivedData(withRootObject: item, requiringSecureCoding: false)
                try data.write(to: fileURL)
            } catch {
                resolvedPersistPolicy = .disabled
                filename = nil
            }
        }
        else {
            
            resolvedPersistPolicy = .disabled
        }
        
        let item = Seed(key: key, object: item, expirationPolicy: policy, persistancePolicy: resolvedPersistPolicy, filename: filename)
        syncAdd(item, with: key)
        
        if resolvedPersistPolicy != .disabled {
         
            persist()
        }
        
        let _ = Timer.scheduledTimer(withTimeInterval: policy.interval, repeats: false) { [weak self] (_) in

            guard let strongSelf = self else { return }
            let _storage = strongSelf.storageCopy
            guard let item = _storage[key] else { return }

            if item.persistancePolicy == .disabled || item.persistancePolicy == .mirror {

                strongSelf.removeItem(with: key)
            }
            else {

                item.invalidateObject()
            }
        }
    }
    
    
    fileprivate func syncAdd(_ item: Seed, with key: String) {
        
        queue.sync { storage[key] = item }
    }
    
    
    // MARK: Remove
    
    open func removeItem(with key: String) {
        
        let _storage = storageCopy
        guard let item = _storage[key] else { return }
        var needsPersistance = false

        if item.persistancePolicy != .disabled {
            
            needsPersistance = true
            
            DispatchQueue.global(qos: DispatchQoS.QoSClass.background).async { () -> Void in
                
                do {
                    
                    if let documentsURL = Nest.documentsURL(), let filename = item.filename {
                        
                        let fileURL = documentsURL.appendingPathComponent(filename)
                        try FileManager.default.removeItem(at: fileURL)
                    }
                }
                catch {}
            }
        }
        
        syncRemove(itemWith: key)
        if needsPersistance {
            
            persist()
        }
    }
    
    
    fileprivate func syncRemove(itemWith key: String) {
        
        let _ = queue.sync { storage.removeValue(forKey: key) }
    }
    
    
    // MARK: Clear
    
    open func clear(ItemsOf owner: String? = nil) {
        
        guard let owner = owner else {

            let _storage = storageCopy
            _storage.forEach { (_, item) in

                if let filename = item.filename, let documentsURL = Nest.documentsURL() {

                    let fileURL = documentsURL.appendingPathComponent(filename)
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
            queue.sync { storage.removeAll() }
            persist()
            return
        }
        
        var keysToClear = [String]()
        var needsPersistance = false

        let _storage = storageCopy

        _storage.forEach { (key, item) in

            if key.hasPrefix(owner) {

                keysToClear.append(key)

                if item.persistancePolicy != .disabled {

                    needsPersistance = true
                }
            }
        }
        
        for key in keysToClear {
            
            removeItem(with: key)
        }
        
        if needsPersistance {
            
            persist()
        }
    }
    
    
    open func clearExpired() {
        
        var keysToRemove = [String]()
        let now = Date()

        let _storage = storageCopy
        
        _storage.forEach { (key, item) in
            
            if let expirationDate = item.expirationDate {
                
                if expirationDate < now {
                    
                    keysToRemove.append(key)
                }
            }
        }
        
        keysToRemove.forEach { (key) in
            
            removeItem(with: key)
        }
    }
    
    
    // MARK: Persistance
    
    fileprivate func persist() {
        
        var persistableContent = [Seed]()

        let _storage = storageCopy
        
        _storage.forEach { (_, item) in
            
            if item.persistancePolicy != .disabled {
                
                persistableContent.append(item)
            }
        }
        
        DispatchQueue.global(qos: DispatchQoS.QoSClass.background).async { () -> Void in

            if let data = try? NSKeyedArchiver.archivedData(withRootObject: persistableContent, requiringSecureCoding: true) {
                try? data.write(to: URL(fileURLWithPath: Nest.indexFilePath()))
            }
        }
    }
    
    
    fileprivate func load() {
        
        var expiredItems = [String]()
        
        if let data = try? Data(contentsOf: URL(fileURLWithPath: Nest.indexFilePath())),
           let archivedContents = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, Seed.self, NSString.self], from: data) as? [Seed] {
            
            let now = Date()
            
            archivedContents.forEach({ (item) in
                
                if let expirationDate = item.persistanceExpirationDate, expirationDate > now {
                 
                    storage[item.key] = item
                }
                else if let filename = item.filename {
                    
                    expiredItems.append(filename)
                }
            })
        }
        
        if let documentsURL = Nest.documentsURL(), expiredItems.count > 0 {
            
            expiredItems.forEach({ (filename) in
                
                let fileURL = documentsURL.appendingPathComponent(filename)
                do { try FileManager.default.removeItem(at: fileURL) }
                catch {}
            })
            
            expiredItems.removeAll()
        }
    }
    
    
    // MARK: Keys
    
    open class func key(with owner: String, parameters: [String]) -> String {
        
        return "\(owner)-\(parameters.joined(separator: "|"))"
    }
    
    
    // MARK: Convenience Methods
    
    fileprivate class func documentsURL() -> URL? {
        
        #if os(Linux)
            return nil
        #else
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        #endif
    }
    
    
    fileprivate class func indexFilePath() -> String {
        
        guard let documentsURL = Nest.documentsURL() else {
        
            return indexFilename
        }
        
        let fileURL = documentsURL.appendingPathComponent(indexFilename)
        return fileURL.path
    }
}
