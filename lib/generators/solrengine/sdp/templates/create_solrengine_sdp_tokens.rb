# Engine-owned record of a token issued through SDP — created off-chain, then
# deployed on-chain. See Solrengine::Sdp::Token for the lifecycle.
class CreateSolrengineSdpTokens < ActiveRecord::Migration[7.1]
  def change
    create_table :solrengine_sdp_tokens do |t|
      t.string :sdp_token_id           # SDP token record id (set on create)
      t.string :mint_address           # on-chain mint (set on deploy)
      t.string :name, null: false
      t.string :symbol, null: false
      t.integer :decimals, null: false, default: 0
      t.string :signing_wallet_id, null: false # mint authority (treasury)
      t.string :status, null: false, default: "created" # created -> deployed -> failed
      t.string :sdp_error

      t.timestamps
    end

    add_index :solrengine_sdp_tokens, :sdp_token_id, unique: true
  end
end
