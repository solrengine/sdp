# Engine-owned record of every mint attempted through SDP — the audit trail
# and the never-double-mint guard. See Solrengine::Sdp::TokenMint.
class CreateSolrengineSdpTokenMints < ActiveRecord::Migration[7.1]
  def change
    create_table :solrengine_sdp_token_mints do |t|
      t.references :token, null: false, foreign_key: { to_table: :solrengine_sdp_tokens }
      t.string :destination, null: false
      t.string :amount, null: false          # decimal token amount — never a float
      t.string :memo                         # app memo (composes with memo_token)
      t.string :memo_token, null: false      # engine reconcile token
      t.string :status, null: false, default: "minting" # minting -> minted | failed | unknown
      t.string :signature
      t.string :sdp_transaction_id
      t.string :token_account
      t.string :sdp_error
      t.datetime :submitted_at
      t.datetime :settled_at

      t.timestamps
    end

    add_index :solrengine_sdp_token_mints, :memo_token, unique: true
    add_index :solrengine_sdp_token_mints, :status
  end
end
