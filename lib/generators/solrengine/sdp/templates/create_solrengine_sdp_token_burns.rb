# Engine-owned record of every burn attempted through SDP — the audit trail
# and the never-double-burn guard. See Solrengine::Sdp::TokenBurn.
class CreateSolrengineSdpTokenBurns < ActiveRecord::Migration[7.1]
  def change
    create_table :solrengine_sdp_token_burns do |t|
      t.references :token, null: false, foreign_key: { to_table: :solrengine_sdp_tokens }
      t.string :source, null: false            # wallet (pubkey) the tokens are burned from
      t.string :signing_wallet_id, null: false # SDP wallet that signs (the source's owner)
      t.string :amount, null: false            # decimal token amount — never a float
      t.string :memo
      t.string :memo_token, null: false        # engine reconcile token
      t.string :status, null: false, default: "burning" # burning -> burned | failed | unknown
      t.string :signature
      t.string :sdp_transaction_id
      t.string :sdp_error
      t.datetime :submitted_at
      t.datetime :settled_at

      t.timestamps
    end

    add_index :solrengine_sdp_token_burns, :memo_token, unique: true
    add_index :solrengine_sdp_token_burns, :status
  end
end
