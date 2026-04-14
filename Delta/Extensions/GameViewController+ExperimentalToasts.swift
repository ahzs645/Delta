//
//  GameViewController+ExperimentalToasts.swift
//  Delta
//
//  Created by Chris Rittenhouse on 4/26/23.
//  Copyright © 2023 Riley Testut. All rights reserved.
//

import Roxas

extension GameViewController
{
    func presentExperimentalToastView(_ text: String)
    {
        guard ExperimentalFeatures.shared.toastNotifications.isEnabled else { return }
        
        DispatchQueue.main.async {
            let toastView = RSTToastView(text: text, detailText: nil)
            toastView.edgeOffset.vertical = 8
            toastView.textLabel.textAlignment = .center
            toastView.presentationEdge = .top
            // Show in the window so the toast renders above the pause menu blur overlay.
            let superview = self.view.window ?? self.view!
            toastView.show(in: superview, duration: ExperimentalFeatures.shared.toastNotifications.duration)
        }
    }
}
