//
//  GameControllerInputMapping.swift
//  Delta
//
//  Created by Riley Testut on 8/30/16.
//  Copyright (c) 2016 Riley Testut. All rights reserved.
//

import Foundation

import DeltaCore
import Harmony

@objc(GameControllerInputMapping)
public class GameControllerInputMapping: _GameControllerInputMapping
{
    private var inputMapping: DeltaCore.GameControllerInputMapping {
        get { return self.deltaCoreInputMapping as! DeltaCore.GameControllerInputMapping }
        set { self.deltaCoreInputMapping = newValue }
    }
    
    public convenience init(inputMapping: DeltaCore.GameControllerInputMapping, context: NSManagedObjectContext)
    {
        self.init(entity: GameControllerInputMapping.entity(), insertInto: context)
        
        self.inputMapping = inputMapping
    }
    
    public override func awakeFromInsert()
    {
        super.awakeFromInsert()
        
        self.identifier = UUID().uuidString
    }
}

extension GameControllerInputMapping
{
    private static let dsGameTypeIdentifier = "com.rileytestut.delta.game.ds"
    private static let touchScreenXIdentifier = "touchScreenX"
    private static let touchScreenYIdentifier = "touchScreenY"

    class func inputMapping(for gameController: GameController, gameType: GameType, in managedObjectContext: NSManagedObjectContext) -> GameControllerInputMapping?
    {
        guard let playerIndex = gameController.playerIndex else {
            return nil
        }
                
        let fetchRequest: NSFetchRequest<GameControllerInputMapping> = GameControllerInputMapping.fetchRequest()
        fetchRequest.returnsObjectsAsFaults = false
        fetchRequest.predicate = NSPredicate(format: "%K == %@ AND %K == %@ AND %K == %d", #keyPath(GameControllerInputMapping.gameControllerInputType), gameController.inputType.rawValue, #keyPath(GameControllerInputMapping.gameType), gameType.rawValue, #keyPath(GameControllerInputMapping.playerIndex), playerIndex)
        
        do
        {
            let inputMappings = try managedObjectContext.fetch(fetchRequest)
            
            let inputMapping = inputMappings.first(where: { !$0.isDeleted })
            return inputMapping
        }
        catch
        {
            print(error)
            
            return nil
        }        
    }
}

private extension GameControllerInputMapping
{
    func isDSTouchControllerInput(_ controllerInput: Input) -> Bool
    {
        guard self.gameType.rawValue == Self.dsGameTypeIdentifier else { return false }
        guard self.gameControllerInputType == .controllerSkin else { return false }
        guard controllerInput.type == .controller(.controllerSkin) else { return false }
        
        switch controllerInput.stringValue
        {
        case Self.touchScreenXIdentifier, Self.touchScreenYIdentifier: return true
        default: return false
        }
    }
    
    func canonicalDSTouchInput(for controllerInput: Input) -> Input?
    {
        guard self.isDSTouchControllerInput(controllerInput) else { return nil }
        guard let deltaCore = Delta.core(for: self.gameType) else { return nil }
        
        let gameInput = deltaCore.gameInputType.init(stringValue: controllerInput.stringValue)
        return gameInput
    }
    
    func normalizedDSTouchInput(for controllerInput: Input, mappedInput: Input?) -> Input?
    {
        guard let canonicalInput = self.canonicalDSTouchInput(for: controllerInput) else { return mappedInput }
        
        guard let mappedInput else { return canonicalInput }
        
        guard mappedInput.type == .game(self.gameType), mappedInput.stringValue == canonicalInput.stringValue else {
            return canonicalInput
        }
        
        return mappedInput
    }
    
}

extension GameControllerInputMapping: GameControllerInputMappingProtocol
{
    var name: String? {
        get { return self.inputMapping.name }
        set { self.inputMapping.name = newValue }
    }
    
    var supportedControllerInputs: [Input] {
        return self.inputMapping.supportedControllerInputs
    }
    
    public func input(forControllerInput controllerInput: Input) -> Input?
    {
        let mappedInput = self.inputMapping.input(forControllerInput: controllerInput)
        return self.normalizedDSTouchInput(for: controllerInput, mappedInput: mappedInput)
    }
    
    func set(_ input: Input?, forControllerInput controllerInput: Input)
    {
        self.inputMapping.set(input, forControllerInput: controllerInput)
    }
}

extension GameControllerInputMapping: Syncable
{
    public static var syncablePrimaryKey: AnyKeyPath {
        return \GameControllerInputMapping.identifier
    }

    public var syncableKeys: Set<AnyKeyPath> {
        return [\GameControllerInputMapping.deltaCoreInputMapping,
                \GameControllerInputMapping.gameControllerInputType,
                \GameControllerInputMapping.gameType,
                \GameControllerInputMapping.playerIndex]
    }
    
    public var syncableLocalizedName: String? {
        return self.name
    }
    
    public func resolveConflict(_ record: AnyRecord) -> ConflictResolution
    {
        return .newest
    }
}
