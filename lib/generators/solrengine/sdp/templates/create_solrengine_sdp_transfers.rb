# Engine-owned record of every transfer the app attempts through SDP — the
# row is the audit trail and the thing the app renders. See
# Solrengine::Sdp::Transfer for the status state machine.
class CreateSolrengineSdpTransfers < ActiveRecord::Migration[7.1]
  def change
    create_table :solrengine_sdp_transfers do |t|
      t.string :sdp_transfer_id              # nil until SDP responds (POST timeout → reconcile)
      t.string :source_wallet_id, null: false
      t.string :destination, null: false
      t.string :token, null: false, default: "SOL"
      t.string :amount, null: false          # decimal string — never a float
      t.string :memo                         # the app's memo (composes with memo_token)
      t.string :memo_token, null: false      # engine reconcile token
      t.string :status, null: false, default: "processing"
      t.string :sdp_status
      t.string :signature
      t.string :sdp_error
      t.datetime :submitted_at
      t.datetime :settled_at

      t.timestamps
    end

    add_index :solrengine_sdp_transfers, :memo_token, unique: true
    add_index :solrengine_sdp_transfers, :status
  end
end
