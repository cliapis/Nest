# Nest - Documentation

Nest is an easy to use cache library written in Swift, compatible with iOS, watchOS, macOS and server side Swift.

## Features
* Swifty syntax
* Thread safe (synchronized reads and writes via GCD serial queue)
* File system persistance policies with NSSecureCoding support
* No dependency on networking libraries
* No limitation on the type of the cached items
* Cached items can be grouped by owner, for grouped management


### Usage
#### Initialization
Initializes the cache and loads the persisted object containers from the disk. The actual persisted object is stored in a different file and will be loaded only if requested.
```Swift
let _ = Nest.shared
```

#### Add item
Adds an object into the cache
```Swift
let item = ["item1", "item2"]
let key = "key"

Nest.shared.add(item: item, withKey: key, expirationPolicy: .short)
```

#### Add - File Persistance
Adds an object into the cache and saves it to disk. Persistance requires the cached object to conform to the NSSecureCoding protocol.
```Swift
let item = ["item1", "item2"]
let key = "key"

Nest.shared.add(item: item, withKey: key, expirationPolicy: .short, andPersistancePolicy: .short)
```

#### Remove item
Removes an item from the cache.
If the item has a persistance policy, the file will be removed too.
```Swift
Nest.shared.removeItem(with: key)
```

#### Get item
Fetches an object from cache.
If, based on the in-memory expiration policy, the object has expired and there is a persistance policy enabled, it will be loaded from disk and the expiration policy will be reissued.
```Swift
let item = Nest.shared[key]
```

#### Clear all items
Removes all items from both memory and disk, cleaning up all persisted files.
```Swift
Nest.shared.clear()
```

#### Clear expired items
Removes items whose expiration date has passed.
```Swift
Nest.shared.clearExpired()
```

### Expiration Policies
There are 6 different expiration policies to choose from. Each one has a corresponding expiration interval. These values can be changed to match the needs of each application. There is also a custom policy where the expiration interval is specified explicitly.
```Swift
public enum ExpirationPolicy: RawRepresentable {

    case short              // 60 seconds
    case medium             // 300 seconds
    case long               // 600 seconds
    case max                // 900 seconds
    case never
    case custom(TimeInterval)
}
```

### Persistance Policies
The persistance policy is different from the expiration policy. For example we may choose to cache an image for 2 minutes in memory, but 2 days in the file system. After the memory expiration, the object is removed from the memory but remains present in the file system. Persistance policies are available for objects implementing the NSSecureCoding protocol. If the object does not conform to NSSecureCoding, the persistance policy is disabled.

```Swift
public enum PersistancePolicy: RawRepresentable {

    case disabled
    case mirror             // mirrors the memory expiration policy
    case short              // 1 day
    case medium             // 3 days
    case long               // 10 days
}
```

### Key Generator
The key is typically a String. Sometimes some items are related under the same entity. These items may require some grouped management, especially on removal.
For example, in an application we have a User Controller to handle all the tasks related to the authenticated user. We may cache many of this data. When the user signs out, we need to remove all these items from our cache.
But how can we do that? We could keep record of all the keys that the controller is using. It works but it's not efficient.

Nest has the ability to know the "owner" of each cached item. This info is stored into the key.
Here is an example

```Swift
class UserController {

    let identifier = "UserController"

    func fetchUserData() {

        // fetch the data..
        // ...

        // add to cache
        let key = Nest.key(with: identifier, parameters: ["userData", username])
        Nest.shared.add(item: userData, withKey: key, expirationPolicy: .short)
    }

    func userDidLogout() {

        Nest.shared.clear(ItemsOf: identifier)
    }
}
```

### Threads and concurrent access
As mentioned above, this implementation is thread safe. Let's say a few words about the implementation.
There are two ways to access the cache: to read (get or enumerate) and to write (add or remove). Swift and GCD (Grand Central Dispatch) gives us the tools to avoid the use of locks, at least not in an explicit way. All write access is driven via a dedicated serial queue to avoid any race condition. Read access is also synchronized through the same queue to obtain a consistent snapshot of the dictionary.

```Swift
let queue = DispatchQueue(label: "com.nest.writeQueue")

fileprivate var storageCopy: [String: Seed] {
    return queue.sync { storage }
}

func syncAdd(_ item: Seed, with key: String) {

    queue.sync { storage[key] = item }
}

func syncRemove(itemWith key: String) {

    let _ = queue.sync { storage.removeValue(forKey: key) }
}
```

All read operations use the `storageCopy` property to obtain a thread-safe snapshot of the dictionary before performing any access or enumeration.

```Swift
subscript (key: String) -> Any? {

    let _storage = storageCopy
    guard let object = _storage[key]?.object else {

        syncRemove(itemWith: key)
        return nil
    }

    return object
}

open func clear(ItemsOf owner: String? = nil) {

    let _storage = storageCopy

     _storage.forEach { (key, item) in
         ...
     }
}
```

## Note
For iOS applications whose state (background, foreground) changes quite often, we should make sure to call `Nest.shared.clearExpired()` in the  `UIApplicationDidBecomeActive` event.
