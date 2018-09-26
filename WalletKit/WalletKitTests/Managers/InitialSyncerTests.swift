import XCTest
import Cuckoo
import RealmSwift
import RxSwift
@testable import WalletKit

class InitialSyncerTests: XCTestCase {

    private var mockHDWallet: MockHDWallet!
    private var mockStateManager: MockStateManager!
    private var mockApiManager: MockApiManager!
    private var mockAddressManager: MockAddressManager!
    private var mockFactory: MockFactory!
    private var mockPeerGroup: MockPeerGroup!
    private var mockNetwork: MockNetworkProtocol!
    private var syncer: InitialSyncer!

    private var realm: Realm!
    private var internalKeys: [PublicKey]!
    private var externalKeys: [PublicKey]!

    override func setUp() {
        super.setUp()

        let mockWalletKit = MockWalletKit()

        mockHDWallet = mockWalletKit.mockHdWallet
        mockStateManager = mockWalletKit.mockStateManager
        mockApiManager = mockWalletKit.mockApiManager
        mockAddressManager = mockWalletKit.mockAddressManager
        mockFactory = mockWalletKit.mockFactory
        mockPeerGroup = mockWalletKit.mockPeerGroup
        mockNetwork = mockWalletKit.mockNetwork
        realm = mockWalletKit.realm

        internalKeys = []
        externalKeys = []
        for i in 0..<5 {
            let internalKey = PublicKey()
            internalKey.address = "internal\(i)"
            internalKey.external = false
            internalKeys.append(internalKey)

            let externalKey = PublicKey()
            externalKey.address = "external\(i)"
            externalKeys.append(externalKey)
        }

        stub(mockHDWallet) { mock in
            when(mock.gapLimit.get).thenReturn(2)
        }
        stub(mockAddressManager) { mock in
            for i in 0..<5 {
                when(mock.publicKey(index: equal(to: i), external: equal(to: false))).thenReturn(internalKeys[i])
                when(mock.publicKey(index: equal(to: i), external: equal(to: true))).thenReturn(externalKeys[i])
            }
        }
        stub(mockStateManager) { mock in
            when(mock.apiSynced.get).thenReturn(false)
            when(mock.apiSynced.set(any())).thenDoNothing()
        }
        stub(mockPeerGroup) { mock in
            when(mock.start()).thenDoNothing()
        }

        let checkpointBlock = Block()
        checkpointBlock.height = 100
        stub(mockNetwork) { mock in
            when(mock.checkpointBlock.get).thenReturn(checkpointBlock)
        }

        syncer = InitialSyncer(
                realmFactory: mockWalletKit.mockRealmFactory,
                hdWallet: mockHDWallet,
                stateManager: mockStateManager,
                apiManager: mockApiManager,
                addressManager: mockAddressManager,
                factory: mockFactory,
                peerGroup: mockPeerGroup,
                network: mockNetwork,
                scheduler: MainScheduler.instance
        )
    }

    override func tearDown() {
        mockHDWallet = nil
        mockStateManager = nil
        mockApiManager = nil
        mockAddressManager = nil
        mockFactory = nil
        mockPeerGroup = nil
        mockNetwork = nil
        syncer = nil

        realm = nil

        super.tearDown()
    }

    func testConnectPeerGroupIfAlreadySynced() {
        stub(mockStateManager) { mock in
            when(mock.apiSynced.get).thenReturn(true)
        }

        try! syncer.sync()

        verify(mockPeerGroup).start()
    }

    func testSuccessSync() {
        let thirdBlock = TestData.thirdBlock
        let secondBlock = thirdBlock.previousBlock!
        let firstBlock = secondBlock.previousBlock!
        thirdBlock.previousBlock = nil
        secondBlock.previousBlock = nil
        firstBlock.previousBlock = nil

        let externalResponse00 = BlockResponse(hash: firstBlock.reversedHeaderHashHex, height: 10)
        let externalResponse01 = BlockResponse(hash: secondBlock.reversedHeaderHashHex, height: 12)
        let internalResponse0 = BlockResponse(hash: thirdBlock.reversedHeaderHashHex, height: 15)

        stub(mockApiManager) { mock in
            when(mock.getBlockHashes(address: equal(to: externalKeys[0].address))).thenReturn(Observable.just([externalResponse00, externalResponse01]))
            when(mock.getBlockHashes(address: equal(to: externalKeys[1].address))).thenReturn(Observable.just([]))
            when(mock.getBlockHashes(address: equal(to: externalKeys[2].address))).thenReturn(Observable.just([]))
            when(mock.getBlockHashes(address: equal(to: internalKeys[0].address))).thenReturn(Observable.just([internalResponse0]))
            when(mock.getBlockHashes(address: equal(to: internalKeys[1].address))).thenReturn(Observable.just([]))
            when(mock.getBlockHashes(address: equal(to: internalKeys[2].address))).thenReturn(Observable.just([]))
        }

        stub(mockFactory) { mock in
            when(mock).block(withHeaderHash: equal(to: firstBlock.headerHash), height: equal(to: externalResponse00.height)).thenReturn(firstBlock)
            when(mock).block(withHeaderHash: equal(to: secondBlock.headerHash), height: equal(to: externalResponse01.height)).thenReturn(secondBlock)
            when(mock).block(withHeaderHash: equal(to: thirdBlock.headerHash), height: equal(to: internalResponse0.height)).thenReturn(thirdBlock)
        }

        try! syncer.sync()

        XCTAssertEqual(realm.objects(Block.self).count, 3)
        XCTAssertEqual(realm.objects(Block.self).filter("reversedHeaderHashHex = %@", externalResponse00.hash).count, 1)
        XCTAssertEqual(realm.objects(Block.self).filter("reversedHeaderHashHex = %@", externalResponse01.hash).count, 1)
        XCTAssertEqual(realm.objects(Block.self).filter("reversedHeaderHashHex = %@", internalResponse0.hash).count, 1)

        verify(mockAddressManager).publicKey(index: equal(to: 0), external: true)
        verify(mockAddressManager).publicKey(index: equal(to: 1), external: true)
        verify(mockAddressManager).publicKey(index: equal(to: 2), external: true)
        verify(mockAddressManager).publicKey(index: equal(to: 0), external: false)
        verify(mockAddressManager).publicKey(index: equal(to: 1), external: false)
        verify(mockAddressManager).publicKey(index: equal(to: 2), external: false)
        verify(mockAddressManager, never()).publicKey(index: equal(to: 3), external: any())

        verify(mockStateManager).apiSynced.set(true)
        verify(mockPeerGroup).start()
    }

    func testSuccessSync_IgnoreBlocksAfterCheckpoint() {
        let secondBlock = TestData.secondBlock
        let firstBlock = secondBlock.previousBlock!
        secondBlock.previousBlock = nil
        firstBlock.previousBlock = nil

        let externalResponse0 = BlockResponse(hash: firstBlock.reversedHeaderHashHex, height: 10)
        let externalResponse1 = BlockResponse(hash: secondBlock.reversedHeaderHashHex, height: 112)

        stub(mockApiManager) { mock in
            when(mock.getBlockHashes(address: equal(to: externalKeys[0].address))).thenReturn(Observable.just([externalResponse0]))
            when(mock.getBlockHashes(address: equal(to: externalKeys[1].address))).thenReturn(Observable.just([externalResponse1]))
            when(mock.getBlockHashes(address: equal(to: externalKeys[2].address))).thenReturn(Observable.just([]))
            when(mock.getBlockHashes(address: equal(to: externalKeys[3].address))).thenReturn(Observable.just([]))
            when(mock.getBlockHashes(address: equal(to: internalKeys[0].address))).thenReturn(Observable.just([]))
            when(mock.getBlockHashes(address: equal(to: internalKeys[1].address))).thenReturn(Observable.just([]))
        }

        stub(mockFactory) { mock in
            when(mock).block(withHeaderHash: equal(to: firstBlock.headerHash), height: equal(to: externalResponse0.height)).thenReturn(firstBlock)
        }

        try! syncer.sync()

        XCTAssertEqual(realm.objects(Block.self).count, 1)
        XCTAssertEqual(realm.objects(Block.self).filter("reversedHeaderHashHex = %@", externalResponse0.hash).count, 1)

        verify(mockAddressManager).publicKey(index: equal(to: 0), external: true)
        verify(mockAddressManager).publicKey(index: equal(to: 1), external: true)
        verify(mockAddressManager).publicKey(index: equal(to: 2), external: true)
        verify(mockAddressManager).publicKey(index: equal(to: 3), external: true)
        verify(mockAddressManager).publicKey(index: equal(to: 0), external: false)
        verify(mockAddressManager).publicKey(index: equal(to: 1), external: false)
        verify(mockAddressManager, never()).publicKey(index: equal(to: 4), external: equal(to: true))
        verify(mockAddressManager, never()).publicKey(index: equal(to: 2), external: equal(to: false))

        verify(mockStateManager).apiSynced.set(true)
        verify(mockPeerGroup).start()
    }

    func testFailedSync_ApiError() {
        let firstBlock = TestData.firstBlock
        firstBlock.previousBlock = nil

        let externalResponse = BlockResponse(hash: firstBlock.reversedHeaderHashHex, height: 10)

        stub(mockApiManager) { mock in
            when(mock.getBlockHashes(address: equal(to: externalKeys[0].address))).thenReturn(Observable.just([externalResponse]))
            when(mock.getBlockHashes(address: equal(to: externalKeys[1].address))).thenReturn(Observable.error(ApiError.noConnection))
            when(mock.getBlockHashes(address: equal(to: internalKeys[0].address))).thenReturn(Observable.just([]))
            when(mock.getBlockHashes(address: equal(to: internalKeys[1].address))).thenReturn(Observable.just([]))
        }

        stub(mockFactory) { mock in
            when(mock).block(withHeaderHash: equal(to: firstBlock.headerHash), height: equal(to: externalResponse.height)).thenReturn(firstBlock)
        }

        try! syncer.sync()

        XCTAssertEqual(realm.objects(Block.self).count, 0)

        verify(mockStateManager, never()).apiSynced.set(true)
        verify(mockPeerGroup, never()).start()
    }

    func testSuccessSync_GapLimit() {
        let thirdBlock = TestData.thirdBlock
        let secondBlock = thirdBlock.previousBlock!
        let firstBlock = secondBlock.previousBlock!
        thirdBlock.previousBlock = nil
        secondBlock.previousBlock = nil
        firstBlock.previousBlock = nil

        let response1 = BlockResponse(hash: firstBlock.reversedHeaderHashHex, height: 10)
        let response2 = BlockResponse(hash: secondBlock.reversedHeaderHashHex, height: 12)
        let response3 = BlockResponse(hash: thirdBlock.reversedHeaderHashHex, height: 15)

        stub(mockApiManager) { mock in
            when(mock.getBlockHashes(address: equal(to: externalKeys[0].address))).thenReturn(Observable.just([response1, response2]))
            when(mock.getBlockHashes(address: equal(to: externalKeys[1].address))).thenReturn(Observable.just([]))
            when(mock.getBlockHashes(address: equal(to: externalKeys[2].address))).thenReturn(Observable.just([response3]))
            when(mock.getBlockHashes(address: equal(to: externalKeys[3].address))).thenReturn(Observable.just([]))
            when(mock.getBlockHashes(address: equal(to: externalKeys[4].address))).thenReturn(Observable.just([]))
            when(mock.getBlockHashes(address: equal(to: internalKeys[0].address))).thenReturn(Observable.just([]))
            when(mock.getBlockHashes(address: equal(to: internalKeys[1].address))).thenReturn(Observable.just([]))
        }

        stub(mockFactory) { mock in
            when(mock).block(withHeaderHash: equal(to: firstBlock.headerHash), height: equal(to: response1.height)).thenReturn(firstBlock)
            when(mock).block(withHeaderHash: equal(to: secondBlock.headerHash), height: equal(to: response2.height)).thenReturn(secondBlock)
            when(mock).block(withHeaderHash: equal(to: thirdBlock.headerHash), height: equal(to: response3.height)).thenReturn(thirdBlock)
        }

        try! syncer.sync()

        XCTAssertEqual(realm.objects(Block.self).count, 3)
        XCTAssertEqual(realm.objects(Block.self).filter("reversedHeaderHashHex = %@", response1.hash).count, 1)
        XCTAssertEqual(realm.objects(Block.self).filter("reversedHeaderHashHex = %@", response2.hash).count, 1)
        XCTAssertEqual(realm.objects(Block.self).filter("reversedHeaderHashHex = %@", response3.hash).count, 1)

        verify(mockAddressManager).publicKey(index: equal(to: 0), external: true)
        verify(mockAddressManager).publicKey(index: equal(to: 1), external: true)
        verify(mockAddressManager).publicKey(index: equal(to: 2), external: true)
        verify(mockAddressManager).publicKey(index: equal(to: 3), external: true)
        verify(mockAddressManager).publicKey(index: equal(to: 4), external: true)
        verify(mockAddressManager).publicKey(index: equal(to: 0), external: false)
        verify(mockAddressManager).publicKey(index: equal(to: 1), external: false)
        verify(mockAddressManager, never()).publicKey(index: equal(to: 5), external: equal(to: true))
        verify(mockAddressManager, never()).publicKey(index: equal(to: 2), external: equal(to: false))

        verify(mockStateManager).apiSynced.set(true)
        verify(mockPeerGroup).start()
    }

}
