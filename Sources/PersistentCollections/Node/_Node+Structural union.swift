//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Collections open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

extension _Node {
  @inlinable
  internal func union(
    _ level: _Level,
    _ hashPrefix: _Hash,
    _ other: _Node
  ) -> (copied: Bool, node: _Node) {
    guard self.count > 0 else { return (true, other) }
    guard other.count > 0 else { return (false, self) }
    if level.isAtRoot, self.hasSingletonItem {
      // In this special case, the root node may turn into a collision node
      // during the merge process. Prevent this from causing issues below by
      // handling it up front.
      return self.read { l in
        let lp = l.itemPtr(at: .zero)
        var copy = other
        let r = copy.updateValue(
          level, forKey: lp.pointee.key, _Hash(lp.pointee.key)
        ) {
          $0.initialize(to: lp.pointee)
        }
        if !r.inserted {
          UnsafeHandle.update(r.leaf) {
            $0[item: r.slot] = lp.pointee
          }
        }
        return (true, copy)
      }
    }
    return _union(level, hashPrefix, other)
  }

  @inlinable
  internal func _union(
    _ level: _Level,
    _ hashPrefix: _Hash,
    _ other: _Node
  ) -> (copied: Bool, node: _Node) {
    if self.raw.storage === other.raw.storage {
      return (false, self)
    }

    if self.isCollisionNode || other.isCollisionNode {
      return _union_slow(level, hashPrefix, other)
    }

    return self.read { l in
      other.read { r in
        var node = self
        var copied = false

        for (bucket, lslot) in l.itemMap {
          assert(!node.isCollisionNode)
          if r.itemMap.contains(bucket) {
            let rslot = r.itemMap.slot(of: bucket)
            let lp = l.itemPtr(at: lslot)
            let rp = r.itemPtr(at: rslot)
            if lp.pointee.key != rp.pointee.key {
              let slot = (
                copied
                ? node.read { $0.itemMap.slot(of: bucket) }
                : lslot)
              _ = node.ensureUniqueAndSpawnChild(
                isUnique: copied,
                level: level,
                replacing: bucket,
                itemSlot: slot,
                newHash: _Hash(rp.pointee.key),
                { $0.initialize(to: rp.pointee) })
              // If we hadn't handled the singleton root node case above,
              // then this call would sometimes turn `node` into a collision
              // node on a compressed path, causing mischief.
              assert(!node.isCollisionNode)
              copied = true
            }
          }
          else if r.childMap.contains(bucket) {
            let rslot = r.childMap.slot(of: bucket)
            let rp = r.childPtr(at: rslot)

            node.ensureUnique(
              isUnique: copied, withFreeSpace: _Node.spaceForSpawningChild)
            let item = node.removeItem(at: bucket)
            let r = rp.pointee.inserting(level.descend(), item, _Hash(item.key))
            node.insertChild(r.node, bucket)
            copied = true
          }
        }

        for (bucket, lslot) in l.childMap {
          assert(!node.isCollisionNode)
          if r.itemMap.contains(bucket) {
            let rslot = r.itemMap.slot(of: bucket)
            let rp = r.itemPtr(at: rslot)
            let h = _Hash(rp.pointee.key)
            let r = l[child: lslot].inserting(level.descend(), rp.pointee, h)
            guard r.inserted else {
              // Nothing to do
              continue
            }
            node.ensureUnique(isUnique: copied)
            let delta = node.replaceChild(at: bucket, with: r.node)
            assert(delta == 1)
            copied = true
          }
          else if r.childMap.contains(bucket) {
            let rslot = r.childMap.slot(of: bucket)
            let child = l[child: lslot]._union(
              level.descend(),
              hashPrefix.appending(bucket, at: level),
              r[child: rslot])
            guard child.copied else {
              // Nothing to do
              continue
            }
            node.ensureUnique(isUnique: copied)
            let delta = node.replaceChild(at: bucket, with: child.node)
            assert(delta > 0) // If we didn't add an item, why did we copy?
            copied = true
          }
        }

        assert(!node.isCollisionNode)

        /// Add buckets in `other` that we haven't processed above.
        let seen = l.itemMap.union(l.childMap)

        for (bucket, _) in r.itemMap.subtracting(seen) {
          let rslot = r.itemMap.slot(of: bucket)
          node.ensureUniqueAndInsertItem(
            isUnique: copied, r[item: rslot], at: bucket)
          copied = true
        }
        for (bucket, _) in r.childMap.subtracting(seen) {
          let rslot = r.childMap.slot(of: bucket)
          node.ensureUnique(
            isUnique: copied, withFreeSpace: _Node.spaceForNewChild)
          copied = true
          node.insertChild(r[child: rslot], bucket)
        }

        return (copied, node)
      }
    }
  }

  @inlinable @inline(never)
  internal func _union_slow(
    _ level: _Level,
    _ hashPrefix: _Hash,
    _ other: _Node
  ) -> (copied: Bool, node: _Node) {
    let lc = self.isCollisionNode
    let rc = other.isCollisionNode
    if lc && rc {
      return read { l in
        other.read { r in
          guard l.collisionHash == r.collisionHash else {
            let node = _Node.build(
              level: level,
              child1: self, l.collisionHash,
              child2: other, r.collisionHash)
            return (true, node)
          }
          var copied = false
          var node = self
          let litems = l.reverseItems
          for rs: _Slot in stride(from: .zero, to: r.itemsEndSlot, by: 1) {
            let p = r.itemPtr(at: rs)
            if !litems.contains(where: { $0.key == p.pointee.key }) {
              _ = node.ensureUniqueAndAppendCollision(
                isUnique: copied, p.pointee)
              copied = true
            }
          }
          return (copied, node)
        }
      }
    }

    // One of the nodes must be on a compressed path.
    assert(!level.isAtBottom)

    if lc {
      // `self` is a collision node on a compressed path. The other tree might
      // have the same set of collisions, just expanded a bit deeper.
      return read { l in
        other.read { r in
          let bucket = l.collisionHash[level]
          if r.itemMap.contains(bucket) {
            let rslot = r.itemMap.slot(of: bucket)
            let rp = r.itemPtr(at: rslot)
            if
              r.hasSingletonItem
              && l.reverseItems.contains(where: { $0.key == rp.pointee.key })
            {
              return (false, self)
            }
            let node = other.copyNodeAndPushItemIntoNewChild(
              level: level,
              self,
              at: bucket,
              itemSlot: rslot)
            return (true, node)
          }

          if r.childMap.contains(bucket) {
            let rslot = r.childMap.slot(of: bucket)
            let h = hashPrefix.appending(bucket, at: level)
            let res = self._union(level.descend(), h, r[child: rslot])
            var node = other.copy()
            let delta = node.replaceChild(at: bucket, rslot, with: res.node)
            assert(delta >= 0)
            return (true, node)
          }

          var node = other.copy(withFreeSpace: _Node.spaceForNewChild)
          node.insertChild(self, bucket)
          return (true, node)
        }
      }
    }

    assert(rc)
    // `other` is a collision node on a compressed path.
    return read { l in
      other.read { r in
        let bucket = r.collisionHash[level]
        if l.itemMap.contains(bucket) {
          let lslot = l.itemMap.slot(of: bucket)
          assert(!l.hasSingletonItem) // Handled up front above
          let node = self.copyNodeAndPushItemIntoNewChild(
            level: level,
            other,
            at: bucket,
            itemSlot: lslot)
          return (true, node)
        }
        if l.childMap.contains(bucket) {
          let lslot = l.childMap.slot(of: bucket)
          let h = hashPrefix.appending(bucket, at: level)
          let child = l[child: lslot]._union(level.descend(), h, other)
          guard child.copied else { return (false, self) }
          var node = self.copy()
          let delta = node.replaceChild(at: bucket, lslot, with: child.node)
          assert(delta > 0) // If we didn't add an item, why did we copy?
          return (true, node)
        }

        var node = self.copy(withFreeSpace: _Node.spaceForNewChild)
        node.insertChild(other, bucket)
        return (true, node)
      }
    }
  }
}
